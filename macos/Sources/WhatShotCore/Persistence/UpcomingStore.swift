import Foundation
import SQLite3

public struct UpcomingStore: Sendable {
  private let queue: DatabaseQueue
  public init(queue: DatabaseQueue) { self.queue = queue }

  /// 调用方只能提交完整来源批次。身份／编码／SQL 任一步失败都不改变旧快照。
  public func replace(_ rows: [UpcomingRelease], source: UpcomingSource, at now: Date) async throws {
    guard (!rows.isEmpty || source == .whenToStream), Set(rows.map(\.id)).count == rows.count,
          rows.allSatisfy({ $0.source == source && !$0.sourceID.isEmpty && !$0.title.isEmpty
            && ["movie", "series"].contains($0.kind)
            && ($0.releaseDate == nil || MovieReleaseDate.isValid($0.releaseDate!))
            && ($0.releaseTime == nil || ($0.releaseDate != nil && Self.validTime($0.releaseTime!)))
          }) else { throw UpcomingError("来源片单校验失败，旧快照已保留") }
    let payloads = try rows.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    let stamp = Int(now.timeIntervalSince1970)
    try Task.checkCancellation()
    try await queue.run { db in
      try Task.checkCancellation()
      try db.exec("BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { try? db.exec("ROLLBACK") } }
      try UpcomingWishlistStore.recordSnapshot(rows, source: source, at: now, db: db)
      let mark = try db.prepare("UPDATE upcoming_releases SET active=0, removed_at=COALESCE(removed_at,?) WHERE source=?")
      defer { sqlite3_finalize(mark) }
      SQLiteDatabase.bind(mark, 1, stamp)
      SQLiteDatabase.bind(mark, 2, source.rawValue)
      guard sqlite3_step(mark) == SQLITE_DONE else { throw DatabaseError(message: "待播旧快照标记失败") }
      let insert = try db.prepare("""
        INSERT INTO upcoming_releases (id,source,kind,title,release_date,release_time,payload,active,fetched_at,removed_at)
        VALUES (?,?,?,?,?,?,?,1,?,NULL)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title,release_date=excluded.release_date,
          release_time=excluded.release_time,payload=excluded.payload,active=1,fetched_at=excluded.fetched_at,removed_at=NULL
        """)
      defer { sqlite3_finalize(insert) }
      for (row, payload) in zip(rows, payloads) {
        try Task.checkCancellation()
        for (index, value) in [row.id, source.rawValue, row.kind, row.title, row.releaseDate, row.releaseTime, payload].enumerated() {
          SQLiteDatabase.bind(insert, Int32(index + 1), value)
        }
        SQLiteDatabase.bind(insert, 8, stamp)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw DatabaseError(message: "待播快照写入失败") }
        sqlite3_reset(insert)
      }
      let state = try db.prepare("""
        INSERT INTO upcoming_source_state (source,last_attempt_at,last_success_at,item_count,error) VALUES (?,?,?,?,NULL)
        ON CONFLICT(source) DO UPDATE SET last_attempt_at=excluded.last_attempt_at,
          last_success_at=excluded.last_success_at,item_count=excluded.item_count,error=NULL
        """)
      defer { sqlite3_finalize(state) }
      SQLiteDatabase.bind(state, 1, source.rawValue)
      SQLiteDatabase.bind(state, 2, stamp)
      SQLiteDatabase.bind(state, 3, stamp)
      SQLiteDatabase.bind(state, 4, rows.count)
      guard sqlite3_step(state) == SQLITE_DONE else { throw DatabaseError(message: "待播来源状态写入失败") }
      let cleanup = try db.prepare("DELETE FROM upcoming_releases WHERE active=0 AND removed_at < ?")
      defer { sqlite3_finalize(cleanup) }
      SQLiteDatabase.bind(cleanup, 1, stamp - 30 * 86400)
      guard sqlite3_step(cleanup) == SQLITE_DONE else { throw DatabaseError(message: "待播历史清理失败") }
      try Task.checkCancellation()
      try db.exec("COMMIT")
      committed = true
    }
  }

  public func recordFailure(_ source: UpcomingSource, message: String, at now: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("""
        INSERT INTO upcoming_source_state (source,last_attempt_at,error) VALUES (?,?,?)
        ON CONFLICT(source) DO UPDATE SET last_attempt_at=excluded.last_attempt_at,error=excluded.error
        """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, source.rawValue)
      SQLiteDatabase.bind(stmt, 2, Int(now.timeIntervalSince1970))
      SQLiteDatabase.bind(stmt, 3, message)
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError(message: "待播失败状态写入失败") }
    }
  }

  public func states() async throws -> [UpcomingSourceState] {
    try await queue.run { db in
      let stmt = try db.prepare("SELECT source,last_attempt_at,last_success_at,item_count,error FROM upcoming_source_state")
      defer { sqlite3_finalize(stmt) }
      var rows: [UpcomingSourceState] = []
      while true {
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW, let source = UpcomingSource(rawValue: db.text(stmt, 0) ?? "") else {
          throw DatabaseError(message: "待播来源状态读取失败")
        }
        rows.append(UpcomingSourceState(source: source,
          lastAttemptAt: db.int(stmt, 1).map { Date(timeIntervalSince1970: Double($0)) },
          lastSuccessAt: db.int(stmt, 2).map { Date(timeIntervalSince1970: Double($0)) },
          count: db.int(stmt, 3) ?? 0, error: db.text(stmt, 4)))
      }
      return rows
    }
  }

  public func releases(sources: [UpcomingSource], region: String? = nil, kind: String? = nil, window: UpcomingWindow = .future,
                       now: Date = .now, offset: Int = 0, limit: Int = 60) async throws -> [UpcomingRelease] {
    guard !sources.isEmpty else { return [] }
    return try await queue.run { db in
      var conditions = ["active=1", "source IN (\(sources.map { _ in "?" }.joined(separator: ",")))"]
      var values = Self.calendarValues(at: now) + sources.map(\.rawValue)
      if let region { conditions.append("json_extract(payload,'$.region')=?"); values.append(region) }
      if let kind { conditions.append("kind=?"); values.append(kind) }
      switch window {
      case .future: conditions.append("release_date>=calendar.today")
      case .undated: conditions.append("release_date IS NULL")
      case .recent: conditions.append("release_date>=calendar.past AND release_date<calendar.today")
      }
      let order = window == .recent ? "release_date DESC" : "release_date ASC"
      let stmt = try db.prepare("""
        WITH calendar(region,today,past) AS (VALUES ('CN',?,?),('US',?,?))
        SELECT payload FROM upcoming_releases JOIN calendar
          ON calendar.region=CASE WHEN json_extract(payload,'$.region')='US' THEN 'US' ELSE 'CN' END
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY \(order),release_time IS NULL,release_time ASC,title COLLATE NOCASE,id
        LIMIT ? OFFSET ?
        """)
      defer { sqlite3_finalize(stmt) }
      for (index, value) in values.enumerated() { SQLiteDatabase.bind(stmt, Int32(index + 1), value) }
      SQLiteDatabase.bind(stmt, Int32(values.count + 1), max(1, min(limit, 60)))
      SQLiteDatabase.bind(stmt, Int32(values.count + 2), max(0, offset))
      var rows: [UpcomingRelease] = []
      while true {
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW, let payload = db.text(stmt, 0) else { throw DatabaseError(message: "待播片单读取失败") }
        rows.append(try JSONDecoder().decode(UpcomingRelease.self, from: Data(payload.utf8)))
      }
      return rows
    }
  }

  /// 合并地区时仍按各地区日历筛选；美东仅为美区日期窗口基准，不推测上线时区。
  private static func calendarValues(at now: Date) -> [String] {
    ["CN", "US"].flatMap { region in
      let past = UpcomingDate.calendar(region: region).date(byAdding: .day, value: -14, to: now)!
      return [UpcomingDate.day(now, region: region), UpcomingDate.day(past, region: region)]
    }
  }

  private static func validTime(_ value: String) -> Bool {
    let parts = value.split(separator: ":")
    return value.count == 5 && parts.count == 2 && (Int(parts[0]).map { (0...23).contains($0) } ?? false)
      && (Int(parts[1]).map { (0...59).contains($0) } ?? false)
  }

  /// 先聚合作品再分页；避免同一作品跨页、跨日期或待定档重复占卡位。
  public func works(sources: [UpcomingSource], region: String? = nil, kind: String? = nil, window: UpcomingWindow = .future,
                    now: Date = .now, offset: Int = 0, limit: Int = 60) async throws -> [UpcomingWork] {
    guard !sources.isEmpty else { return [] }
    return try await queue.run { db in
      var conditions = ["active=1", "source IN (\(sources.map { _ in "?" }.joined(separator: ",")))"]
      var values = Self.calendarValues(at: now) + sources.map(\.rawValue)
      if let region { conditions.append("json_extract(payload,'$.region')=?"); values.append(region) }
      if let kind { conditions.append("kind=?"); values.append(kind) }
      // 完整标题只折叠首尾空格和大小写，不删除季数、年份、副标题或版本标记。
      // 同平台多个不同 ID 同名说明存在歧义，整组拆开，避免误并重拍作品。
      let dateFilter: String
      switch window {
      case .future: dateFilter = "anchor>=grouped.today"
      case .undated: dateFilter = "anchor IS NULL"
      case .recent: dateFilter = "anchor>=grouped.past AND anchor<grouped.today"
      }
      let order = window == .recent ? "DESC" : "ASC"
      let stmt = try db.prepare("""
        WITH calendar(region,today,past) AS (VALUES ('CN',?,?),('US',?,?)), base AS (
          SELECT upcoming_releases.*,calendar.today,calendar.past,
            json_array(lower(trim(title)),kind,json_extract(payload,'$.region'),
            json_extract(payload,'$.releaseType')) AS candidate
          FROM upcoming_releases JOIN calendar
            ON calendar.region=CASE WHEN json_extract(payload,'$.region')='US' THEN 'US' ELSE 'CN' END
          WHERE \(conditions.joined(separator: " AND "))
        ), ambiguous AS (
          SELECT candidate FROM base GROUP BY candidate,source HAVING COUNT(*)>1
        ), keyed AS (
          SELECT *, CASE WHEN candidate IN (SELECT candidate FROM ambiguous)
            THEN json_array(candidate,id) ELSE candidate END AS work_key FROM base
        ), grouped AS (
          SELECT work_key, MIN(today) AS today, MIN(past) AS past,
            COALESCE(MIN(CASE WHEN release_date>=today THEN release_date END),MAX(release_date)) AS anchor
          FROM keyed GROUP BY work_key
        ), selected AS (
          SELECT grouped.*, MIN(CASE WHEN keyed.release_date=anchor THEN keyed.release_time END) AS sort_time
          FROM grouped JOIN keyed USING(work_key) WHERE \(dateFilter)
          GROUP BY work_key ORDER BY anchor \(order),sort_time IS NULL,sort_time,work_key LIMIT ? OFFSET ?
        )
        SELECT selected.work_key,selected.anchor,keyed.payload FROM selected JOIN keyed USING(work_key)
        ORDER BY selected.anchor \(order),selected.sort_time IS NULL,selected.sort_time,selected.work_key,
          CASE keyed.source WHEN 'youku' THEN 0 WHEN 'iqiyi' THEN 1 ELSE 2 END,keyed.id
        """)
      defer { sqlite3_finalize(stmt) }
      for (index, value) in values.enumerated() { SQLiteDatabase.bind(stmt, Int32(index + 1), value) }
      SQLiteDatabase.bind(stmt, Int32(values.count + 1), max(1, min(limit, 60)))
      SQLiteDatabase.bind(stmt, Int32(values.count + 2), max(0, offset))
      var result: [UpcomingWork] = []
      var ids: [String] = []
      var dates: [String: String] = [:]
      var groupedRows: [String: [UpcomingRelease]] = [:]
      while true {
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW, let key = db.text(stmt, 0), let payload = db.text(stmt, 2) else {
          throw DatabaseError(message: "待播作品分组读取失败")
        }
        if groupedRows[key] == nil { ids.append(key) }
        dates[key] = db.text(stmt, 1)
        groupedRows[key, default: []].append(try JSONDecoder().decode(UpcomingRelease.self, from: Data(payload.utf8)))
      }
      for id in ids { result.append(UpcomingWork(id: id, releaseDate: dates[id], releases: groupedRows[id]!)) }
      return result
    }
  }
}
