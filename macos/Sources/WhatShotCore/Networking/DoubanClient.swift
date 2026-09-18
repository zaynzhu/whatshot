import Foundation

/// 豆瓣首播日补全客户端：一期单源的明确例外（2026-09-13 定案）。
/// 范围收窄为一件事：用库内已有 douban_id 请求 rexxar 详情，只解析 pubdate 首播日。
/// 不做标题搜索、不补评分/简介/海报/逐集；失败不阻断主同步。
/// 接口档案见 docs/butai0-api.md「播出日期可得性结论」。
public struct DoubanClient: Sendable {
  /// 豆瓣限流/反爬信号：命中时整批停止退避（429 尊重 Retry-After 由调用方处理，401/403 立即停批）
  public enum DoubanError: Error, Sendable {
    case blocked(status: Int)        // 401/403/安全验证页：当批停止，不重试不绕过
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse(String)
  }

  static let baseURL = "https://m.douban.com/rexxar/api/v2"
  static let requestHeaders = [
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
    "Referer": "https://m.douban.com/tv",
    "Accept": "application/json"
  ]

  let limiter: RateLimiter
  let session: URLSession

  /// 独立限频器：与 butai0 客户端各自计数。
  /// 豆瓣用 6.5±1.5 秒随机抖动（实测 2 秒等差节奏两天累计 ~195 条后触发 403 风控；
  /// 随机化是最便宜的缓解，红队审查 2026-09-14）
  public init(limiter: RateLimiter = RateLimiter(interval: 6.5, jitter: 1.5), session: URLSession = .shared) {
    self.limiter = limiter
    self.session = session
  }

  /// 拉一部剧的首播日。返回 YYYY-MM-DD；无完整日期返回 nil（豆瓣没有≠失败）。
  /// 429 → rateLimited（含 Retry-After）；401/403/404 以外的 4xx/5xx → invalidResponse。
  public func fetchPremiereDate(doubanId: Int) async throws -> String? {
    await limiter.waitTurn()
    guard let url = URL(string: "\(Self.baseURL)/tv/\(doubanId)") else {
      throw DoubanError.invalidResponse("URL 构造失败")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    for (key, value) in Self.requestHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw DoubanError.invalidResponse("响应不是 HTTP")
    }
    switch http.statusCode {
    case 200..<300:
      break
    case 429:
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
      throw DoubanError.rateLimited(retryAfter: retryAfter)
    case 401, 403:
      throw DoubanError.blocked(status: http.statusCode)
    default:
      // 404 = 豆瓣无此条目（或 movie/tv kind 不符），不算失败但也没有日期
      if http.statusCode == 404 { return nil }
      throw DoubanError.invalidResponse("HTTP \(http.statusCode)")
    }
    return Self.parsePremiereDate(from: data)
  }

  /// 海报兜底（2026-09-18）：取豆瓣海报大图 URL（pic.large，doubanio 域名，下载需 Referer）。
  /// 库内 kind 与豆瓣 kind 不一致实测存在（因果报应库内 kind=电影 但 /tv/ 404），
  /// 先试 /tv/ 再回退 /movie/；两路都 404 返回 nil。首播日与海报共用同一限频器
  public func fetchPosterPath(doubanId: Int) async throws -> String? {
    if let path = try await fetchPosterPath(doubanId: doubanId, kindPath: "tv") {
      return path
    }
    return try await fetchPosterPath(doubanId: doubanId, kindPath: "movie")
  }

  private func fetchPosterPath(doubanId: Int, kindPath: String) async throws -> String? {
    await limiter.waitTurn()
    guard let url = URL(string: "\(Self.baseURL)/\(kindPath)/\(doubanId)") else {
      throw DoubanError.invalidResponse("URL 构造失败")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    for (key, value) in Self.requestHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw DoubanError.invalidResponse("响应不是 HTTP")
    }
    switch http.statusCode {
    case 200..<300:
      break
    case 429:
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
      throw DoubanError.rateLimited(retryAfter: retryAfter)
    case 401, 403:
      throw DoubanError.blocked(status: http.statusCode)
    default:
      // 404 = 豆瓣该 kind 无此条目，不算失败（调用方会回退另一路径）
      if http.statusCode == 404 { return nil }
      throw DoubanError.invalidResponse("HTTP \(http.statusCode)")
    }
    return Self.parsePosterPath(from: data)
  }

  /// 解析 pic.large（完整大图 URL）。pic 可能是对象（rexxar v2）或字符串，都兼容；
  /// 只收 https 且为 doubanio 域名（macOS ATS 禁明文 http，红线不豁免；非豆瓣图不兜）
  public static func parsePosterPath(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let raw: String?
    if let pic = json["pic"] as? [String: Any] {
      raw = pic["large"] as? String ?? pic["normal"] as? String
    } else {
      raw = json["pic"] as? String
    }
    guard let url = raw, url.hasPrefix("https://"), url.contains("doubanio.com") else { return nil }
    return url
  }

  /// 解析 pubdate：收集所有完整 YYYY-MM-DD 日期（不分地区），取最早的一个 = 真实首播日
  /// （2026-09-13 用户定案"全都要"：地区白名单与优先级都不要）。
  /// 仅年份/无完整日期不补假日期（不把仅年份补成 1-1），按自然日存。
  /// 样例：["2026-08-31(中国大陆)"] → "2026-08-31"；["2026-09-10(韩国)"] → "2026-09-10"；
  /// ["2026-09-01(美国)", "2026-08-20(中国大陆)"] → "2026-08-20"（最早优先）；["2025(美国)"] → nil
  public static func parsePremiereDate(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pubdates = json["pubdate"] as? [String] else {
      return nil
    }
    var earliest: String?
    for pubdate in pubdates {
      // 拆「日期(地区)」：地区标记不参与过滤
      let datePart = pubdate.split(separator: "(", maxSplits: 1).first
        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      // 完整日期校验：YYYY-MM-DD 严格 10 位
      guard datePart.count == 10, datePart[datePart.index(datePart.startIndex, offsetBy: 4)] == "-" else { continue }
      let digits = datePart.replacingOccurrences(of: "-", with: "")
      guard digits.count == 8, digits.allSatisfy(\.isNumber) else { continue }
      // YYYY-MM-DD 字典序即时间序，直接字符串比较取最早
      if earliest == nil || datePart < earliest! { earliest = datePart }
    }
    return earliest
  }
}