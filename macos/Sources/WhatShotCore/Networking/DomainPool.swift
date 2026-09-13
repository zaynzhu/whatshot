import Foundation

/// butai0 站点域名池：站点官方公布多个备用域名（同一数据库的不同 CDN 路由）。
/// 优先从发布页 https://www.butailing.com/ 自动发现（页面 HOSTS 数组），
/// 内置官方池只作发布页不可达时的兜底——站点更换域名家族时不再需要改代码。
/// 用户自定义地址（settings.baseURL）恒为最高优先成员。
public enum DomainPool {
  /// 发布页地址（域名家族的官方公布处）
  public static let publishPageURL = "https://www.butailing.com/"

  /// 内置兜底池：2026-09-13 从发布页确认的全部 16 个官方域名。
  /// 仅在发布页抓取失败时使用；新域名靠 fetchPublishedDomains 自动进池
  public static let fallbackDomains: [String] = [
    "https://www.butai0.club",
    "https://www.butai0.com",
    "https://www.butai0.dev",
    "https://www.butai0.one",
    "https://www.butai0.vip",
    "https://www.butai0.xyz",
    "https://www.0bt0.com",
    "https://www.1bt0.com",
    "https://www.2bt0.com",
    "https://www.3bt0.com",
    "https://www.4bt0.com",
    "https://www.5bt0.com",
    "https://www.6bt0.com",
    "https://www.7bt0.com",
    "https://www.8bt0.com",
    "https://www.9bt0.com",
  ]

  /// 同步链路用别名（AppModel/SyncEngine 调用），语义不变
  public static var officialDomains: [String] { fallbackDomains }

  /// 抓发布页发现官方域名。失败（网络/解析异常/无结果）返回 nil，调用方静默回落兜底池。
  /// 页面结构（2026-09-13 实测）：`const HOSTS = [ "www.0bt0.com", … ]`，正则抓引号内域名
  public static func fetchPublishedDomains(session: URLSession = .shared, timeout: TimeInterval = 10) async -> [String]? {
    guard let url = URL(string: publishPageURL) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      return nil
    }
    return parsePublishPage(String(decoding: data, as: UTF8.self))
  }

  /// 解析发布页 HTML → 规范化域名数组。HOSTS 数组外的内容不收；解析出 0 个返回 nil
  public static func parsePublishPage(_ html: String) -> [String]? {
    // 只在 const HOSTS = [ … ] 区间内收域名，避免把页面其他链接（统计脚本等）误入池
    guard let hostsRange = html.range(of: "const HOSTS"),
          let arrayStart = html.range(of: "[", range: hostsRange.upperBound..<html.endIndex) else {
      return nil
    }
    let arrayEnd = html.range(of: "]", range: arrayStart.upperBound..<html.endIndex)?.lowerBound
      ?? html.endIndex
    guard arrayStart.upperBound <= arrayEnd else { return nil }
    let body = html[arrayStart.upperBound..<arrayEnd]
    // 引号内取域名样式字符串（www.xxx.tld），拒绝路径/参数/脚本片段
    let pattern = #/"([a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,})"*/#
    var domains: [String] = []
    for match in body.matches(of: pattern) {
      let host = String(match.1)
      if host.contains("butailing.com") { continue } // 发布页自身不入池
      if let normalized = normalized(host) {
        domains.append(normalized)
      }
    }
    var seen = Set<String>()
    let unique = domains.filter { seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique
  }

  /// 组装同步用域名候选序列：自定义地址最高优先 + 发布页发现域 + 内置兜底池，去重
  /// 输入允许带不带协议与末尾斜杠
  public static func candidates(customBaseURL: String?, published: [String]? = nil) -> [String] {
    var pool: [String] = []
    if let custom = normalized(customBaseURL) {
      pool.append(custom)
    }
    if let published, !published.isEmpty {
      pool.append(contentsOf: published)
    }
    pool.append(contentsOf: fallbackDomains)
    var seen = Set<String>()
    return pool.filter { seen.insert($0).inserted }
  }

  /// 规范化：补 https 协议、去末尾斜杠、空白转空
  public static func normalized(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
      value = "https://" + value
    }
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }
}

/// 探活结果：域名 + 实测 HEAD 延迟
public struct DomainProbe: Sendable, Equatable {
  public let baseURL: String
  public let latency: TimeInterval

  public init(baseURL: String, latency: TimeInterval) {
    self.baseURL = baseURL
    self.latency = latency
  }
}

/// 域名择优器：探活选路 + 冠军记忆 + 失败降级。
/// 探活走真实 API 路径的 HEAD（完整 DNS+TCP+TLS+服务器链路），不占 2 秒限频额度
/// （HEAD 无响应体，单域名一次；与正式同步共用 RateLimiter 时按站点语义仍由调用方控制）。
public actor DomainSelector {
  /// 上次冠军域名；nil = 首次
  private var champion: String?
  private let session: URLSession
  private let probePath: String

  public init(session: URLSession = .shared) {
    self.session = session
    // 探活路径用固定公开参数的合法接口地址，保证 HEAD 不被网关拒绝
    self.probePath = "/prod/api/v1/getVideoList?sc=3&app_id=83768d9ad4&identity=23734adac0301bccdcb107c4aa21f96c"
  }

  /// 手动钉住域名的探活确认：通了设为冠军供同步直接用；不通返回 nil（调用方回落自动择优）。
  /// 与 pickBest 的区别：不做全池比较——钉住语义是"优先用它"，不是"在它和其他之间选最快"
  public func probePinned(_ baseURL: String, timeout: TimeInterval = 4) async -> DomainProbe? {
    guard let probe = await probeOne(baseURL, timeout: timeout) else { return nil }
    champion = baseURL
    return probe
  }

  /// 择优入口：先探冠军（上次成功的域名），通了直接用；失败才全池并行探活取最快。
  /// 返回 nil = 全池不可达。
  public func pickBest(candidates: [String], timeout: TimeInterval = 4) async -> DomainProbe? {
    // 1. 冠军快路径
    if let champion, candidates.contains(champion) {
      if let probe = await probeOne(champion, timeout: timeout) {
        return probe
      }
    }
    // 2. 全池并行探活
    let probes = await withTaskGroup(of: DomainProbe?.self) { group in
      for base in candidates where base != champion {
        group.addTask { await self.probeOne(base, timeout: timeout) }
      }
      var results: [DomainProbe] = []
      for await case let probe? in group {
        results.append(probe)
      }
      return results
    }
    guard let best = probes.min(by: { $0.latency < $1.latency }) else {
      return nil
    }
    champion = best.baseURL
    return best
  }

  /// 域名故障降级：同步中连续失败后调用，把当前冠军排除后重新择优
  public func demoteAndPick(candidates: [String], timeout: TimeInterval = 4) async -> DomainProbe? {
    if let failing = champion {
      var rest = candidates
      rest.removeAll { $0 == failing }
      champion = nil
      if let probe = await pickBest(candidates: rest, timeout: timeout) {
        return probe
      }
      // 其余全部失败时允许回落到原域名（可能只是瞬时抖动）
      champion = failing
    }
    return nil
  }

  /// 当前冠军（供 UI 展示「当前域名」）
  public var currentDomain: String? {
    champion
  }

  private func probeOne(_ baseURL: String, timeout: TimeInterval) async -> DomainProbe? {
    guard let url = URL(string: baseURL + probePath) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "HEAD"
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
    let start = Date()
    guard let (data, response) = try? await session.data(for: request),
          data.isEmpty || true, // HEAD 无 body；个别服务器可能回 200+空体，都算通
          let http = response as? HTTPURLResponse,
          (200..<400).contains(http.statusCode) else {
      return nil
    }
    return DomainProbe(baseURL: baseURL, latency: Date().timeIntervalSince(start))
  }
}