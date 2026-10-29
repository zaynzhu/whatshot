import Foundation
import SQLite3

/// 站内三榜属于同一个来源；各榜保留独立名次和观察时间。
public struct LocalChartSignal: Sendable, Equatable, Identifiable {
  public let scope: ButaiChartScope
  public let rank: Int
  public let observedAt: Date
  public let consecutiveDays: Int
  public var id: String { scope.rawValue }

  public init(scope: ButaiChartScope, rank: Int, observedAt: Date, consecutiveDays: Int = 1) {
    self.scope = scope
    self.rank = rank
    self.observedAt = observedAt
    self.consecutiveDays = consecutiveDays
  }

  public func isFresh(at now: Date = .now) -> Bool {
    rank > 0 && (-300...172800).contains(now.timeIntervalSince(observedAt))
  }
}

public enum WorkHeatTier: Sendable, Equatable {
  case none, local, external, shared

  public static func resolve(local: [LocalChartSignal], external: [ExternalHeatStore.DisplayRow], now: Date = .now) -> Self {
    let localHot = local.contains { $0.isFresh(at: now) }
    let externalHot = ExternalSignalPresentation.hasHeat(external, now: now)
    return switch (localHot, externalHot) {
    case (true, true): .shared
    case (true, false): .local
    case (false, true): .external
    default: .none
    }
  }
}

/// 只读已有榜单观察；一次载入最多三榜的当前成员，不载入整部片库。
public struct LocalChartStore: Sendable {
  let queue: DatabaseQueue
  public init(queue: DatabaseQueue) { self.queue = queue }

  public func signals(now: Date = .now) async throws -> [Int: [LocalChartSignal]] {
    try await queue.run { db in
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
      let cutoff = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now))!
      var result: [Int: [LocalChartSignal]] = [:]
      for scope in ButaiChartScope.allCases {
        let stmt = try db.prepare("""
          SELECT video_id, chart_rank, observed_at FROM observations
          WHERE chart_scope=? AND chart_rank>0 AND
            (observed_at>=? OR observed_at=(SELECT MAX(observed_at) FROM observations WHERE chart_scope=?))
          ORDER BY observed_at DESC
          """)
        defer { sqlite3_finalize(stmt) }
        SQLiteDatabase.bind(stmt, 1, scope.rawValue)
        SQLiteDatabase.bind(stmt, 2, Int(cutoff.timeIntervalSince1970))
        SQLiteDatabase.bind(stmt, 3, scope.rawValue)
        var batches: [Int: [Int: Int]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
          guard let videoID = db.int(stmt, 0), let rank = db.int(stmt, 1), let time = db.int(stmt, 2) else { continue }
          batches[time, default: [:]][videoID] = rank
        }
        let times = batches.keys.sorted(by: >)
        guard let latest = times.first, let current = batches[latest] else { continue }
        for (videoID, rank) in current {
          var days = 0
          var previousDay: Date?
          for time in times {
            guard let batch = batches[time], batch[videoID] != nil,
                  Double(batch.count) >= Double(current.count) * 0.85 else { break }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(time)))
            if let previousDay {
              let gap = calendar.dateComponents([.day], from: day, to: previousDay).day ?? 0
              if gap > 1 { break }
              if gap == 0 { continue }
            }
            days += 1
            previousDay = day
          }
          result[videoID, default: []].append(LocalChartSignal(scope: scope, rank: rank,
            observedAt: Date(timeIntervalSince1970: Double(latest)), consecutiveDays: max(1, min(14, days))))
        }
      }
      return result
    }
  }
}
