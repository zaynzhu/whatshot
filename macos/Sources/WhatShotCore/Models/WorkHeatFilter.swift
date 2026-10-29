import Foundation

public enum WorkHeatFilter: String, CaseIterable, Sendable {
  case all = "全部"
  case local = "站内热门"
  case external = "外部热榜"
  case shared = "多榜共热"
}

/// 只保存已精确关联的本地身份，与海报使用相同的新鲜度和热度口径。
public struct WorkHeatMembership: Equatable, Sendable {
  public let local: Set<Int>
  public let external: Set<Int>

  public init(local: [Int: [LocalChartSignal]], external: [ExternalHeatStore.DisplayRow],
              externalEnabled: Bool, now: Date = .now) {
    self.local = Set(local.compactMap { id, signals in
      signals.contains { $0.isFresh(at: now) } ? id : nil
    })
    self.external = externalEnabled ? Set(external.compactMap { row in
      ExternalSignalPresentation.isHeat(row.source) && ExternalSignalPresentation.isFresh(row, now: now)
        ? row.video?.id : nil
    }) : []
  }

  public func ids(for filter: WorkHeatFilter) -> Set<Int>? {
    switch filter {
    case .all: nil
    case .local: local
    case .external: external
    case .shared: local.intersection(external)
    }
  }
}
