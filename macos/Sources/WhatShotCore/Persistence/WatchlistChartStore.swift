import Foundation
import SQLite3

public struct WatchlistChartEntry: Sendable, Identifiable {
  public let videoID: Int
  public let scope: ButaiChartScope
  public let rank: Int
  public let observedAt: Date
  public var id: String { "\(videoID)|\(scope.rawValue)" }
}

extension LocalChartStore {
  /// 近 48 小时关注后的入榜事实。只比较相邻同榜、间隔不超过 48 小时的可信批次。
  public func watchlistEntries(now: Date = .now) async throws -> [WatchlistChartEntry] {
    try await queue.run { db in
      let stmt = try db.prepare("""
        WITH batches AS (
          SELECT chart_scope,observed_at,COUNT(*) AS size FROM observations
          WHERE chart_rank>0 AND chart_scope IN ('3','4','5') AND observed_at>=?
          GROUP BY chart_scope,observed_at
        ), pairs AS (
          SELECT *,LAG(observed_at) OVER(PARTITION BY chart_scope ORDER BY observed_at) AS previous_at,
            LAG(size) OVER(PARTITION BY chart_scope ORDER BY observed_at) AS previous_size FROM batches
        ), entries AS (
          SELECT o.video_id,o.chart_scope,o.chart_rank,o.observed_at,
            ROW_NUMBER() OVER(PARTITION BY o.video_id,o.chart_scope ORDER BY o.observed_at DESC) AS position
          FROM pairs b JOIN observations o ON o.chart_scope=b.chart_scope AND o.observed_at=b.observed_at
          JOIN watchlist w ON w.video_id=o.video_id
          WHERE o.chart_rank>0 AND o.observed_at>w.created_at AND o.observed_at>=? AND o.observed_at<=?
            AND b.previous_at IS NOT NULL AND b.observed_at-b.previous_at<=172800
            AND b.previous_size>=b.size*0.85
            AND NOT EXISTS(SELECT 1 FROM observations old WHERE old.chart_scope=b.chart_scope
              AND old.observed_at=b.previous_at AND old.video_id=o.video_id AND old.chart_rank>0)
        )
        SELECT video_id,chart_scope,chart_rank,observed_at FROM entries WHERE position=1 ORDER BY observed_at DESC,video_id,chart_scope
        """)
      defer { sqlite3_finalize(stmt) }
      let stamp = Int(now.timeIntervalSince1970)
      SQLiteDatabase.bind(stmt, 1, stamp - 4 * 86400)
      SQLiteDatabase.bind(stmt, 2, stamp - 2 * 86400)
      SQLiteDatabase.bind(stmt, 3, stamp)
      var rows: [WatchlistChartEntry] = []
      while true {
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW, let scope = ButaiChartScope(rawValue: db.text(stmt, 1) ?? "") else {
          throw DatabaseError(message: "关注作品入榜记录读取失败")
        }
        rows.append(.init(videoID: db.int(stmt, 0)!, scope: scope, rank: db.int(stmt, 2)!,
          observedAt: Date(timeIntervalSince1970: Double(db.int(stmt, 3)!))))
      }
      return rows
    }
  }
}
