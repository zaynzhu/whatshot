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

  /// 独立限频器：与 butai0 客户端各自计数，均 ≥2 秒间隔
  public init(limiter: RateLimiter = RateLimiter(), session: URLSession = .shared) {
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

  /// 解析 pubdate：数组内只取「完整 YYYY-MM-DD 且标注中国大陆」的日期；
  /// 其他精度/地区不补假日期（不把仅年份补成 1-1），按自然日存。
  /// 样例：["2026-08-31(中国大陆)"] → "2026-08-31"；["2025(美国)"] → nil；["2026-08-31"]（无地区）→ nil
  public static func parsePremiereDate(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pubdates = json["pubdate"] as? [String] else {
      return nil
    }
    for pubdate in pubdates {
      // 拆「日期(地区)」：括号内是地区标记
      let parts = pubdate.split(separator: "(", maxSplits: 1).map(String.init)
      let datePart = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      let regionPart = parts.count > 1 ? parts[1].dropLast().description : nil // 去掉右括号
      guard regionPart == "中国大陆" else { continue }
      // 完整日期校验：YYYY-MM-DD 严格 10 位
      guard datePart.count == 10, datePart[datePart.index(datePart.startIndex, offsetBy: 4)] == "-" else { continue }
      let digits = datePart.replacingOccurrences(of: "-", with: "")
      guard digits.count == 8, digits.allSatisfy(\.isNumber) else { continue }
      return datePart
    }
    return nil
  }
}