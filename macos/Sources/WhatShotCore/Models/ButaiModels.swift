import Foundation

/// butai0 接口返回的视频条目。字段语义从站点前端渲染反推，全部可选 + 容错解析，
/// 字段缺失不报错（私有接口随时可能变化）。
public struct ButaiVideo: Sendable, Equatable {
  /// 站点内部数字 ID（详情接口参数 getVideoDetail?id=X 的 X）
  public var id: Int
  /// 豆瓣 subject ID，可作稳定外部身份
  public var doubanId: Int?
  /// 标题
  public var title: String
  /// 原名（外文原标题）
  public var originalTitle: String?
  /// 又名字逗号分隔
  public var alias: String?
  /// 播出进度文本："更新至9集" / "全集" / ""（电影多为空）
  public var episodeStatus: String
  /// 总集数字符串，"0" 表示未知
  public var episodes: String
  /// 画质定义（列表接口为单值，热门接口可能多值逗号分隔）
  public var definition: String?
  /// 年代（四位年份或年代）
  public var years: String?
  /// 类型，逗号分隔
  public var classNames: String?
  /// 制片地区
  public var productionArea: String?
  /// 豆瓣评分字符串，"0" 表示无
  public var doubanScore: String?
  /// IMDb 编号 tt...
  public var imdbNumber: String?
  /// IMDb 评分字符串
  public var imdbScore: String?
  /// 海报 URL
  public var posterURL: String?
  /// 当前种子资源数
  public var seedCount: Int
  /// 当前网盘资源数
  public var netdiskCount: Int
  /// 站点资源最后更新时间（含在播更新信号）
  public var seedUpdatedAt: String?
  /// 站点条目最后更新时间
  public var updatedAt: String?
  /// 导演（详情才有，列表无）
  public var director: String?
  /// 主演（详情才有，列表无）
  public var performer: String?
  /// 剧情简介（详情才有，列表无）
  public var abstract: String?
  /// 首播/上映信息（如 "2026(中国大陆)"）
  public var release: String?
  /// 类型 1=电影 2=剧集（接口 tp/type 字段）
  public var kind: ButaiKind

  public init(
    id: Int, doubanId: Int?, title: String, originalTitle: String?, alias: String?,
    episodeStatus: String, episodes: String, definition: String?, years: String?,
    classNames: String?, productionArea: String?, doubanScore: String?, imdbNumber: String?,
    imdbScore: String?, posterURL: String?, seedCount: Int, netdiskCount: Int,
    seedUpdatedAt: String?, updatedAt: String?, director: String?, performer: String?,
    abstract: String?, release: String?, kind: ButaiKind
  ) {
    self.id = id
    self.doubanId = doubanId
    self.title = title
    self.originalTitle = originalTitle
    self.alias = alias
    self.episodeStatus = episodeStatus
    self.episodes = episodes
    self.definition = definition
    self.years = years
    self.classNames = classNames
    self.productionArea = productionArea
    self.doubanScore = doubanScore
    self.imdbNumber = imdbNumber
    self.imdbScore = imdbScore
    self.posterURL = posterURL
    self.seedCount = seedCount
    self.netdiskCount = netdiskCount
    self.seedUpdatedAt = seedUpdatedAt
    self.updatedAt = updatedAt
    self.director = director
    self.performer = performer
    self.abstract = abstract
    self.release = release
    self.kind = kind
  }

  /// 解析总集数为整数，"0"/空/非数字返回 nil
  public var episodeCount: Int? {
    let value = episodes.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, let count = Int(value), count > 0 else { return nil }
    return count
  }

  /// 从 ejs 文本解析当前更新到第几集："更新至9集" -> 9；"全集" -> episodeCount；其余 nil
  public var currentEpisode: Int? {
    let text = episodeStatus.trimmingCharacters(in: .whitespaces)
    if text.contains("全集") { return episodeCount }
    guard let numberRange = text.range(of: #"更新至(\d+)集"#, options: .regularExpression) else { return nil }
    let digits = text[numberRange].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
    return Int(digits)
  }
}

public enum ButaiKind: Int, Sendable, Equatable {
  case movie = 1
  case tvSeries = 2
}

public enum ButaiChartScope: String, Sendable, CaseIterable {
  /// 近日热门
  case recent = "3"
  /// 本周热门
  case weekly = "4"
  /// 本月热门
  case monthly = "5"

  /// 榜单中文标签
  public var label: String {
    switch self {
    case .recent: return "近日热门"
    case .weekly: return "本周热门"
    case .monthly: return "本月热门"
    }
  }
}

/// 解析错误：只描述无法解析的情况，字段级缺失不算错误
public struct ButaiParseError: Error, Sendable {
  public let message: String
}

/// butai0 JSON 响应解析器，与 HTTP 无关便于单测
public enum ButaiParser {
  /// 统一响应外壳：{"success":true,"code":200,"data":...}
  static func unwrap(_ data: Data) throws -> Any {
    let root = try JSONSerialization.jsonObject(with: data)
    guard let dict = root as? [String: Any] else {
      throw ButaiParseError(message: "响应不是 JSON 对象")
    }
    guard dict["success"] as? Bool == true else {
      let code = dict["code"] as? Int ?? 0
      let message = dict["message"] as? String ?? "未知错误"
      throw ButaiParseError(message: "接口失败 code=\(code) message=\(message)")
    }
    guard let payload = dict["data"] else {
      throw ButaiParseError(message: "响应缺少 data")
    }
    return payload
  }

  /// 热门榜 getVideoList?sc=N → data.data 数组（双层嵌套）
  public static func parseVideoList(_ data: Data) throws -> [ButaiVideo] {
    let payload = try unwrap(data)
    guard let dict = payload as? [String: Any],
          let rows = dict["data"] as? [[String: Any]] else {
      throw ButaiParseError(message: "getVideoList data.data 结构缺失")
    }
    return rows.map(parseVideo)
  }

  /// 列表 getVideoMovieList → data.list 数组（单层）
  /// 列表行不带 tp 字段，分类以拉取来源 sa 参数为准（站点「电影页」也会混入剧集，行内字段不可信）
  public static func parseMovieList(_ data: Data, kind: ButaiKind) throws -> [ButaiVideo] {
    let payload = try unwrap(data)
    guard let dict = payload as? [String: Any],
          let rows = dict["list"] as? [[String: Any]] else {
      throw ButaiParseError(message: "getVideoMovieList data.list 结构缺失")
    }
    return rows.map { parseListVideo($0, kind: kind) }
  }

  /// 详情 getVideoDetail → data 对象
  public static func parseDetail(_ data: Data) throws -> ButaiVideo {
    let payload = try unwrap(data)
    guard let row = payload as? [String: Any] else {
      throw ButaiParseError(message: "getVideoDetail data 不是对象")
    }
    return parseVideo(row)
  }

  /// 热门接口的完整字段行（tp 有值且可信）
  static func parseVideo(_ row: [String: Any]) -> ButaiVideo {
    let kindRaw = (row["tp"] as? Int) ?? (row["type"] as? Int) ?? 2
    return parseListVideo(row, kind: kindRaw == 1 ? .movie : .tvSeries)
  }

  /// 列表接口字段行；kind 由调用方按拉取来源传入，行内 tp/type 缺失或与来源矛盾时以来源为准
  static func parseListVideo(_ row: [String: Any], kind: ButaiKind) -> ButaiVideo {
    let id = (row["id"] as? Int) ?? Int(row["id"] as? String ?? "") ?? 0
    // 热门接口用 idcode，列表接口用 doub_id 作豆瓣 ID
    let doubanId = (row["doub_id"] as? Int)
      ?? (row["doub_id"] as? String).flatMap(Int.init)
      ?? Int(row["idcode"] as? String ?? "") ?? nil
    return ButaiVideo(
      id: id,
      doubanId: doubanId,
      title: row["title"] as? String ?? "",
      originalTitle: row["otitle"] as? String,
      alias: row["alias"] as? String,
      episodeStatus: row["ejs"] as? String ?? "",
      episodes: row["episodes"] as? String ?? "",
      definition: row["definition"] as? String ?? row["zqxd"] as? String ?? row["eqxd"] as? String,
      years: row["years"] as? String ?? row["niandai"] as? String,
      classNames: row["class"] as? String,
      productionArea: row["production_area"] as? String,
      doubanScore: row["doub_score"] as? String,
      imdbNumber: row["IMDB_number"] as? String,
      imdbScore: row["IMDB_score"] as? String,
      posterURL: row["image"] as? String ?? row["epic"] as? String,
      seedCount: (row["seed_num"] as? Int) ?? 0,
      netdiskCount: (row["wp_num"] as? Int) ?? 0,
      seedUpdatedAt: row["seed_updated_at"] as? String,
      updatedAt: row["updated_at"] as? String,
      director: row["director"] as? String,
      performer: row["performer"] as? String,
      abstract: row["abstract"] as? String,
      release: row["release"] as? String,
      kind: kind
    )
  }
}