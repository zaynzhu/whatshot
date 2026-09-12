import Foundation

/// butai0 HTTP 客户端：2 秒限频 + 可配置域名 + 容错
/// baseURL 是「本次同步实际使用的域名」：由 SyncEngine 探活择优后注入（settings.baseURL
/// 作为最高优先候选），不再直接绑定 settings
public struct ButaiClient: Sendable {
  /// 写死在前端 JS 的固定公开参数（缺失时报"接口鉴权失败"）
  static let appID = "83768d9ad4"
  static let identity = "23734adac0301bccdcb107c4aa21f96c"

  /// 本次同步实际使用的域名（规范化后），供降级逻辑比对
  public let baseURL: String
  private let limiter: RateLimiter
  private let session: URLSession

  public init(baseURL: String, limiter: RateLimiter = RateLimiter(), session: URLSession = .shared) {
    guard let normalized = DomainPool.normalized(baseURL) else {
      preconditionFailure("ButaiClient 需要有效域名")
    }
    self.baseURL = normalized
    self.limiter = limiter
    self.session = session
  }

  struct ClientError: Error {
    let message: String
  }

  /// 构造 API URL。baseURL 已在 init 时规范化，此处直接拼接
  func apiURL(path: String, query: [String: String]) throws -> URL {
    guard var components = URLComponents(string: baseURL + "/prod/api/v1/" + path) else {
      throw ClientError(message: "站点地址无效：\(baseURL)")
    }
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "app_id", value: Self.appID))
    items.append(URLQueryItem(name: "identity", value: Self.identity))
    components.queryItems = items
    guard let url = components.url else {
      throw ClientError(message: "URL 构造失败：\(baseURL)")
    }
    return url
  }

  /// 单次 GET，先过限频
  func get(_ url: URL) async throws -> Data {
    await limiter.waitTurn()
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ClientError(message: "响应不是 HTTP")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ClientError(message: "HTTP \(http.statusCode)")
    }
    return data
  }

  /// 热门榜：sc=3 近日 / 4 本周 / 5 本月
  public func fetchChart(_ scope: ButaiChartScope) async throws -> [ButaiVideo] {
    let url = try apiURL(path: "getVideoList", query: ["sc": scope.rawValue])
    return try ButaiParser.parseVideoList(try await get(url))
  }

  /// 电影/剧集列表按更新时间排序翻页；mediaKind 1=电影 2=剧集
  /// 分类以请求参数 sa 为准（列表行无 tp 字段，站点电影页会混入剧集）
  public func fetchMovieList(mediaKind: ButaiKind, page: Int) async throws -> [ButaiVideo] {
    let url = try apiURL(path: "getVideoMovieList", query: [
      "sa": mediaKind == .movie ? "1" : "2",
      "sg": "1",
      "page": String(page)
    ])
    return try ButaiParser.parseMovieList(try await get(url), kind: mediaKind)
  }

  /// 详情
  public func fetchDetail(id: Int) async throws -> ButaiVideo {
    let url = try apiURL(path: "getVideoDetail", query: ["id": String(id)])
    return try ButaiParser.parseDetail(try await get(url))
  }
}