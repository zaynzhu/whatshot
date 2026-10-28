import Foundation

/// 与主站探活独立；每个来源完整成功后才替换本地快照。
public struct UpcomingSync: Sendable {
  private let store: UpcomingStore
  private let fetch: @Sendable (UpcomingSource) async throws -> [UpcomingRelease]

  public init(store: UpcomingStore, client: UpcomingClient) {
    self.store = store
    self.fetch = { try await client.fetch($0) }
  }

  init(store: UpcomingStore, fetch: @escaping @Sendable (UpcomingSource) async throws -> [UpcomingRelease]) {
    self.store = store
    self.fetch = fetch
  }

  public func run(sources: [UpcomingSource], force: Bool, intervalHours: Int,
                  onProgress: @Sendable (String) async -> Void = { _ in }) async throws {
    guard force || intervalHours > 0 else { return }
    let states = try await store.states()
    for source in UpcomingSource.allCases where sources.contains(source) {
      try Task.checkCancellation()
      if !force, let last = states.first(where: { $0.source == source })?.lastSuccessAt,
         Date().timeIntervalSince(last) < Double(intervalHours) * 3600 { continue }
      await onProgress("读取\(source.title)")
      do {
        let rows = try await fetch(source)
        try Task.checkCancellation()
        try await store.replace(rows, source: source, at: .now)
      } catch {
        try Task.checkCancellation()
        // 网络异常只保留错误码，避免 URL 参数／临时令牌进入持久日志。
        let message: String
        if let known = error as? UpcomingError { message = known.message }
        else if let network = error as? URLError { message = "网络请求失败（\(network.code.rawValue)），稍后重试" }
        else { message = "来源解析或保存失败，旧快照已保留" }
        try await store.recordFailure(source, message: message, at: .now)
      }
    }
  }
}
