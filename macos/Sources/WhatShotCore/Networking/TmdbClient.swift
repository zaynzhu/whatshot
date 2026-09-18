import Foundation

/// TMDB 首播日补全客户端：一期例外扩大到第二个外部源（2026-09-15 用户拍板，方案 B）。
/// 范围收窄为一件事：对有 IMDb 号的剧集，补"该季首播日"（不是系列首播日）。
/// 触发逻辑：豆瓣 403 退避期间，欧美剧集（含分季）靠 TMDB 绕开风控先补齐。
/// 不做：标题搜索建身份（错配风险）、评分/简介/海报、电影、自动合并。
///
/// 实测依据（2026-09-15，本库 26 个真实 IMDb ID）：
/// butai0 给剧集挂的 IMDB_number 多为"该季第 1 集"的单集条目（如最后生还者 tt26469967 = S2E1、
/// 权游 tt3658012 = S5E1），TMDB /find 命中 tv_episode_results 时其 air_date 即该季首播日；
/// 少数是系列级条目（夜魔侠重生 tt18923754 → tv_results），此时从中文标题解析季号再查分季。
public struct TmdbClient: Sendable {
  public enum TmdbError: Error, Sendable {
    case invalidResponse(String)
    case notFound            // 全部结果为空：TMDB 无此条目，不算失败
    case unauthorized        // 401：key 无效，当批停止
  }

  /// 一次补全的产物：日期 + 反查所需身份
  public struct SeasonPremiere: Sendable, Equatable {
    public var date: String          // 该季首播日 YYYY-MM-DD
    public var showId: Int           // TMDB 剧集 ID（series id，不是 person）
    public var seasonNumber: Int     // 实际取到日期的季（用于回查/纠错）

    public init(date: String, showId: Int, seasonNumber: Int) {
      self.date = date
      self.showId = showId
      self.seasonNumber = seasonNumber
    }
  }

  static let baseURL = "https://api.themoviedb.org/3"

  let apiKey: String
  let limiter: RateLimiter
  let session: URLSession

  /// 独立限频器：与豆瓣、butai0 各自计数。TMDB 官方限流宽松，按全局规范 ≥2 秒固定间隔即可。
  public init(apiKey: String, limiter: RateLimiter = RateLimiter(interval: 2.0), session: URLSession = .shared) {
    self.apiKey = apiKey
    self.limiter = limiter
    self.session = session
  }

  /// 取一部剧某一季的首播日。imdbId 是 IMDb 编号（tt 开头，可能是单集或系列条目）；
  /// title 是库内中文标题（用于系列级命中时解析"第N季"）。无匹配抛 notFound，401 抛 unauthorized。
  public func fetchSeasonPremiere(imdbId: String, title: String) async throws -> SeasonPremiere {
    // 1. /find：imdb 身份直连建立 TMDB 身份，不做标题搜索（whatsnew 严格模式，错配防线）
    let (data, _) = try await get("/find/\(imdbId)?external_source=imdb_id&language=zh-CN")

    // 2a. 命中单集：air_date 即该季首播日（实测 butai0 挂的多为当季第 1 集）
    if let ep = Self.firstEpisode(from: data) {
      // 季号校验：若库内标题解析得出季号，且与单集季号明显不符，说明 butai0 挂错了 IMDb → 不硬填
      let titleSeason = Self.parseSeasonNumber(from: title)
      if let ts = titleSeason, ts != ep.seasonNumber {
        throw TmdbError.notFound
      }
      // episode_number==1 时单集播出日即季首播日；否则回查该季首集日期
      if ep.episodeNumber == 1 {
        return SeasonPremiere(date: ep.airDate, showId: ep.showId, seasonNumber: ep.seasonNumber)
      }
      if let seasonDate = try await fetchSeasonAirDate(showId: ep.showId, season: ep.seasonNumber) {
        return SeasonPremiere(date: seasonDate, showId: ep.showId, seasonNumber: ep.seasonNumber)
      }
      return SeasonPremiere(date: ep.airDate, showId: ep.showId, seasonNumber: ep.seasonNumber)
    }

    // 2b. 命中系列：从标题解析季号查分季；解析不出按系列第 1 季
    if let showId = Self.firstTvShowId(from: data) {
      let season = Self.parseSeasonNumber(from: title) ?? 1
      if season == 1, let firstAir = Self.firstTvFirstAirDate(from: data) {
        return SeasonPremiere(date: firstAir, showId: showId, seasonNumber: 1)
      }
      guard let seasonDate = try await fetchSeasonAirDate(showId: showId, season: season) else {
        throw TmdbError.notFound
      }
      return SeasonPremiere(date: seasonDate, showId: showId, seasonNumber: season)
    }

    throw TmdbError.notFound
  }

  /// 海报兜底（2026-09-18）：按 IMDb 号取剧集/电影海报的 TMDB 路径（w500 前完整 poster_path，
  /// 如 /abc.jpg——拼接 image.tmdb.org/t/p/w500 使用）。返回 nil = TMDB 无此条目或无海报。
  /// 三种命中桶分路：movie_results/tv_results 直接带 poster_path；
  /// tv_episode_results（butai0 挂的多为单集条目）取 show_id 二跳 /tv/{id} 拿剧集级海报。
  public func fetchPosterPath(imdbId: String) async throws -> String? {
    let (data, _) = try await get("/find/\(imdbId)?external_source=imdb_id&language=zh-CN")
    if let path = Self.firstPosterPath(from: data, key: "movie_results")
      ?? Self.firstPosterPath(from: data, key: "tv_results") {
      return path
    }
    if let showId = Self.firstEpisode(from: data)?.showId {
      let (showData, status) = try await get("/tv/\(showId)?language=zh-CN")
      if status == 404 { return nil }
      return Self.firstPosterPath(from: showData, key: nil)
    }
    return nil
  }

  /// /tv/{show_id}/season/{N}：取该季首播日；该季不存在返回 nil
  private func fetchSeasonAirDate(showId: Int, season: Int) async throws -> String? {
    let (data, status) = try await get("/tv/\(showId)/season/\(season)?language=zh-CN")
    if status == 404 { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return Self.normalizeDate(json["air_date"] as? String)
  }

  // MARK: - HTTP

  /// 统一发 GET。返回 (data, httpStatus)。401 抛 unauthorized（key 无效，调用方停批）
  private func get(_ pathAndQuery: String) async throws -> (Data, Int) {
    await limiter.waitTurn()
    guard let url = URL(string: "\(Self.baseURL)\(pathAndQuery)") else {
      throw TmdbError.invalidResponse("URL 构造失败")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TmdbError.invalidResponse("响应不是 HTTP")
    }
    if http.statusCode == 401 { throw TmdbError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      throw TmdbError.invalidResponse("HTTP \(http.statusCode)")
    }
    return (data, http.statusCode)
  }

  // MARK: - 解析（静态、可单测）

  struct EpisodeHit: Sendable, Equatable {
    var showId: Int
    var seasonNumber: Int
    var episodeNumber: Int
    var airDate: String
  }

  /// /find 的 tv_episode_results[0]：show_id + season/episode 号 + air_date
  static func firstEpisode(from data: Data) -> EpisodeHit? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let episodes = json["tv_episode_results"] as? [[String: Any]],
          let first = episodes.first else {
      return nil
    }
    guard let showId = first["show_id"] as? Int,
          let season = first["season_number"] as? Int,
          let epNum = first["episode_number"] as? Int,
          let airDate = normalizeDate(first["air_date"] as? String) else {
      return nil
    }
    return EpisodeHit(showId: showId, seasonNumber: season, episodeNumber: epNum, airDate: airDate)
  }

  /// /find 的 tv_results[0] 系列 ID（系列级命中）
  static func firstTvShowId(from data: Data) -> Int? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = json["tv_results"] as? [[String: Any]],
          let first = results.first,
          let id = first["id"] as? Int else {
      return nil
    }
    return id
  }

  static func firstTvFirstAirDate(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = json["tv_results"] as? [[String: Any]],
          let first = results.first else {
      return nil
    }
    return normalizeDate(first["first_air_date"] as? String)
  }

  /// 取 JSON 对象/数组首项的 poster_path（/abc.jpg 形态）。key 非 nil 时在指定数组里找，
  /// nil 时把整个 JSON 当对象找（/tv/{id} 详情响应）。路径必须以 / 开头且含文件名，防脏数据
  static func firstPosterPath(from data: Data, key: String?) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let candidates: [[String: Any]]
    if let key {
      guard let list = json[key] as? [[String: Any]] else { return nil }
      candidates = list
    } else {
      candidates = [json]
    }
    for item in candidates {
      if let path = item["poster_path"] as? String, path.hasPrefix("/"), path.count > 4 {
        return path
      }
    }
    return nil
  }

  /// 中文/英文季号解析（对齐 userscript getSeasonNumber + parseChineseNumber）。
  /// "黑袍纠察队 第四季"→4；"仙逆 第一季"→1；"凡人修仙传：星海飞驰篇 第十一季"→11；"Season 5"→5。
  /// 返回 nil = 标题无季号。
  public static func parseSeasonNumber(from title: String) -> Int? {
    // 英文 Season N / 第N季
    if let match = title.range(of: #"Season\s+(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
      let digits = title[match].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
      if let n = Int(digits) { return n }
    }
    // 中文"第N季"：数字或中文数字
    if let match = title.range(of: #"第([0-9一二三四五六七八九十百千]+)季"#, options: .regularExpression) {
      let inner = title[match]
      let body = inner.dropFirst().dropLast()  // 去"第"和"季"
      if let n = Int(body) { return n }
      return parseChineseNumber(String(body))
    }
    return nil
  }

  /// 中文数字 → 阿拉伯数字。一/二/.../十，十一=11，二十=20（按 userscript 规则扩展）
  static func parseChineseNumber(_ str: String) -> Int? {
    let map: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    if str.count == 1, let v = map[str.first!] { return v }
    if str == "十" { return 10 }
    // 十一/十二...：十开头，加各位
    if str.hasPrefix("十") {
      let rest = str.dropFirst()
      if rest.count == 1, let v = map[rest.first!] { return 10 + v }
      return nil
    }
    // 二十/三十...：各位 + 十
    if str.hasSuffix("十"), str.count == 2, let v = map[str.first!] { return v * 10 }
    // 二十一/三十二...：各位 + 十 + 各位
    if str.count == 3, let a = map[str.first!], str[str.index(str.startIndex, offsetBy: 1)] == "十",
       let b = map[str.last!] {
      return a * 10 + b
    }
    return nil
  }

  /// 规范化日期：严格 10 位 YYYY-MM-DD，否则 nil（不补假日期，与豆瓣口径一致）
  static func normalizeDate(_ raw: String?) -> String? {
    guard let s = raw?.trimmingCharacters(in: .whitespaces), s.count == 10 else { return nil }
    guard s[s.index(s.startIndex, offsetBy: 4)] == "-", s[s.index(s.startIndex, offsetBy: 7)] == "-" else { return nil }
    let digits = s.replacingOccurrences(of: "-", with: "")
    guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
    return s
  }
}
