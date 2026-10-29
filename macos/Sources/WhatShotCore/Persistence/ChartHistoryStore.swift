import Foundation
import SQLite3

public struct ChartHistoryDay: Sendable, Equatable, Identifiable {
  public let day: String
  public let rank: Int?
  /// true + 无名次：在当天末次完整快照中未见；false：缺少可判断的采样。
  public let sampled: Bool
  public var id: String { day }
}

public struct ChartHistorySeries: Sendable, Identifiable {
  public let id: String
  public let title: String
  public let context: String
  public let external: Bool
  public let days: [ChartHistoryDay]
}

public struct ChartHistoryStore: Sendable {
  let queue: DatabaseQueue
  public init(queue: DatabaseQueue) { self.queue = queue }

  private static func capturedDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  /// 调用方已开启事务；重复获取同一采集时刻只更新一个点，不把本地刷新次数当历史。
  static func record(_ signal: WhatsNewClient.Signal, fetchedAt: Date, db: SQLiteDatabase) throws {
    guard ExternalSignalPresentation.isHeat(signal.source), signal.isCurrent,
          let rank = signal.rank, rank > 0, let captured = capturedDate(signal.capturedAt),
          (-300...15 * 86400).contains(fetchedAt.timeIntervalSince(captured)) else { return }
    let stmt = try db.prepare("""
      INSERT INTO external_chart_history
        (media_id,source,scope,window,entry_key,region,entry_label,captured_at,rank,fetched_at)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(media_id,source,scope,window,entry_key,region,captured_at)
      DO UPDATE SET rank=excluded.rank,entry_label=excluded.entry_label,fetched_at=excluded.fetched_at
      """)
    defer { sqlite3_finalize(stmt) }
    for (i, value) in [signal.mediaItemId, signal.source, signal.rankingScope ?? "overall",
      signal.window ?? "", signal.rankingEntryKey ?? "work", signal.region ?? "", signal.rankingEntryLabel].enumerated() {
      SQLiteDatabase.bind(stmt, Int32(i + 1), value)
    }
    SQLiteDatabase.bind(stmt, 8, Int(captured.timeIntervalSince1970))
    SQLiteDatabase.bind(stmt, 9, rank)
    SQLiteDatabase.bind(stmt, 10, Int(fetchedAt.timeIntervalSince1970))
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError(message: "榜单轨迹写入失败") }
  }

  public func history(videoID: Int, externalEnabled: Bool, now: Date = .now) async throws -> [ChartHistorySeries] {
    let calendar = UpcomingDate.calendar
    let today = calendar.startOfDay(for: now)
    let dates = (0..<14).map { calendar.date(byAdding: .day, value: $0 - 13, to: today)! }
    let days = dates.map { UpcomingDate.day($0) }
    let cutoff = Int(dates[0].timeIntervalSince1970)
    return try await queue.run { db in
      var result: [ChartHistorySeries] = []
      for scope in ButaiChartScope.allCases {
        let stmt = try db.prepare("""
          SELECT observed_at,COUNT(*),MAX(CASE WHEN video_id=? THEN chart_rank END)
          FROM observations WHERE chart_scope=? AND chart_rank>0 AND observed_at>=? AND observed_at<=?
          GROUP BY observed_at ORDER BY observed_at
          """)
        SQLiteDatabase.bind(stmt, 1, videoID)
        SQLiteDatabase.bind(stmt, 2, scope.rawValue)
        SQLiteDatabase.bind(stmt, 3, cutoff)
        SQLiteDatabase.bind(stmt, 4, Int(now.timeIntervalSince1970))
        var batches: [(time: Int, count: Int, rank: Int?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
          batches.append((db.int(stmt, 0)!, db.int(stmt, 1)!, db.int(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        let maximum = batches.map(\.count).max() ?? 0
        var points: [String: ChartHistoryDay] = [:]
        for batch in batches {
          let day = UpcomingDate.day(Date(timeIntervalSince1970: Double(batch.time)))
          points[day] = ChartHistoryDay(day: day, rank: batch.rank,
            sampled: batch.rank != nil || Double(batch.count) >= Double(maximum) * 0.85)
        }
        result.append(ChartHistorySeries(id: scope.rawValue, title: scope.label,
          context: "butai0 · 当日末次本地快照", external: false,
          days: days.map { points[$0] ?? ChartHistoryDay(day: $0, rank: nil, sampled: false) }))
      }
      guard externalEnabled else { return result }
      // 既有最新快照可作为一个真实采集点；历史缺口不反向填充。
      let stmt = try db.prepare("""
        WITH points AS (
          SELECT media_id,source,scope,window,entry_key,region,entry_label,captured_at,rank,fetched_at
          FROM external_chart_history
          UNION ALL
          SELECT media_id,source,ranking_scope,window,ranking_entry_key,COALESCE(region,''),
            ranking_entry_label,CAST(strftime('%s',captured_at) AS INTEGER),rank,fetched_at
          FROM external_heat WHERE is_current=1 AND rank>0
        )
        SELECT p.media_id,p.source,p.scope,p.window,p.entry_key,p.region,p.entry_label,p.captured_at,p.rank
        FROM points p WHERE p.captured_at>=? AND p.captured_at<=?
          AND EXISTS (SELECT 1 FROM external_heat e WHERE e.media_id=p.media_id AND e.video_id=?)
        ORDER BY p.captured_at,p.fetched_at
        """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, cutoff)
      SQLiteDatabase.bind(stmt, 2, Int(now.timeIntervalSince1970))
      SQLiteDatabase.bind(stmt, 3, videoID)
      var points: [String: [String: ChartHistoryDay]] = [:]
      var labels: [String: (String, String)] = [:]
      while sqlite3_step(stmt) == SQLITE_ROW {
        let source = db.text(stmt, 1) ?? ""
        guard ExternalSignalPresentation.isHeat(source), let time = db.int(stmt, 7),
              let rank = db.int(stmt, 8), rank > 0 else { continue }
        let fields = (0...5).map { db.text(stmt, Int32($0)) ?? "" }
        let key = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        let day = UpcomingDate.day(Date(timeIntervalSince1970: Double(time)))
        points[key, default: [:]][day] = ChartHistoryDay(day: day, rank: rank, sampled: true)
        labels[key] = (ExternalSignalMeaning.label(for: source),
          [fields[2], fields[3], fields[5], db.text(stmt, 6) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
      }
      for key in labels.keys.sorted() {
        result.append(ChartHistorySeries(id: key, title: labels[key]!.0, context: labels[key]!.1,
          external: true, days: days.map { points[key]?[$0] ?? ChartHistoryDay(day: $0, rank: nil, sampled: false) }))
      }
      return result
    }
  }
}
