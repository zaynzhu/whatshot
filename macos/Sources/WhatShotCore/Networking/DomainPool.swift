import Foundation

/// butai0 站点域名池：站点官方公布多个备用域名（同一数据库的不同 CDN 路由），
/// 发布页 https://www.butailing.com/ 按路由展示各域名延迟。默认池内置全部官方域名，
/// 用户自定义地址（settings.baseURL）作为最高优先成员进池。
/// 站点整批更换域名家族时升级此默认池即可；二期可改为从发布页自动发现。
public enum DomainPool {
  /// 站点官方公布的全部域名（2026-09-12 从发布页确认）
  public static let officialDomains: [String] = [
    "https://www.butai0.club",
    "https://www.butai0.com",
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

  /// 组装同步用域名候选序列：自定义地址最高优先 + 去重 + 补全协议
  /// 输入允许带不带协议与末尾斜杠
  public static func candidates(customBaseURL: String?) -> [String] {
    var pool: [String] = []
    if let custom = normalized(customBaseURL) {
      pool.append(custom)
    }
    pool.append(contentsOf: officialDomains)
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