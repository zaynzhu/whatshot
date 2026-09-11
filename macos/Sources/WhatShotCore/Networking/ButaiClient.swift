import Foundation

/// butai0 HTTP 客户端：2 秒限频 + 可配置域名 + 容错
public struct ButaiClient: Sendable {
  /// 写死在前端 JS 的固定公开参数（缺失时报"接口鉴权失败"）
  static let appID = "83768d9ad4"
  static let identity = "23734adac0301bccdcb107c4aa21f96c"

  private let settings: ButaiSettings
  private let limiter: RateLimiter
  private let session: URLSession

  public init(settings: ButaiSettings, limiter: RateLimiter = RateLimiter(), session: URLSession = .shared) {
    self.settings = settings
    self.limiter = limiter
    self.session = session
  }

  struct ClientError: Error {
    let message: String
  }

  /// 构造 API URL。settings.baseURL 允许带不带协议与末尾斜杠
  func apiURL(path: String, query: [String: String]) throws -> URL {
    var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
      base = "https://" + base
    }
    while base.hasSuffix("/") { base.removeLast() }
    guard var components = URLComponents(string: base + "/prod/api/v1/" + path) else {
      throw ClientError(message: "站点地址无效：\(base)")
    }
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "app_id", value: Self.appID))
    items.append(URLQueryItem(name: "identity", value: Self.identity))
    components.queryItems = items
    guard let url = components.url else {
      throw ClientError(message: "URL 构造失败：\(base)")
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
  public func fetchMovieList(mediaKind: ButaiKind, page: Int) async throws -> [ButaiVideo] {
    let url = try apiURL(path: "getVideoMovieList", query: [
      "sa": mediaKind == .movie ? "1" : "2",
      "sg": "1",
      "page": String(page)
    ])
    return try ButaiParser.parseMovieList(try await get(url))
  }

  /// 详情
  public func fetchDetail(id: Int) async throws -> ButaiVideo {
    let url = try apiURL(path: "getVideoDetail", query: ["id": String(id)])
    return try ButaiParser.parseDetail(try await get(url))
  }
}