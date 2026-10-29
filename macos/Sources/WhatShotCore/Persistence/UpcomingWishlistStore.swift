import Foundation
import SQLite3

public enum UpcomingBrowseMode: String, Sendable, CaseIterable {
  case all = "全部片单"
  case wanted = "我的想看"
  case week = "本周想看"
  case today = "今日想看"
  case changes = "排期变动"
}

public struct UpcomingWantChange: Sendable, Identifiable {
  public let id: Int
  public let releaseID: String
  public let reason: String
  public let before: UpcomingRelease
  public let after: UpcomingRelease?
  public let observedAt: Date
  public let isRead: Bool
  public var label: String {
    guard let after, let oldDate = before.releaseDate, let newDate = after.releaseDate else { return reason }
    if oldDate != newDate { return newDate < oldDate ? "提前上线" : "延期上线" }
    if let oldTime = before.releaseTime, let newTime = after.releaseTime, oldTime != newTime {
      return newTime < oldTime ? "时刻提前" : "时刻推迟"
    }
    return reason
  }
  public var summary: String {
    func schedule(_ row: UpcomingRelease) -> String {
      row.releaseDate.map { $0 + " " + row.timeText } ?? "待定档"
    }
    return schedule(before) + " → " + (after.map(schedule) ?? "移出片单，是否上线未确认")
  }
}

public struct UpcomingWishlistStore: Sendable {
  let queue: DatabaseQueue
  public init(queue: DatabaseQueue) { self.queue = queue }

  public func savedIDs() async throws -> Set<String> {
    try await queue.run { db in
      let stmt = try db.prepare("SELECT release_id FROM upcoming_wants")
      defer { sqlite3_finalize(stmt) }
      var ids = Set<String>()
      while sqlite3_step(stmt) == SQLITE_ROW { if let id = db.text(stmt, 0) { ids.insert(id) } }
      return ids
    }
  }

  /// 收藏保存原站身份和快照，不以可变标题或展示分组键作为身份。
  public func setWanted(_ work: UpcomingWork, wanted: Bool, at now: Date = .now) async throws {
    guard !work.releases.isEmpty else { return }
    try await queue.run { db in
      try db.exec("BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { try? db.exec("ROLLBACK") } }
      let ids = work.releases.map(\.id)
      let placeholders = ids.map { _ in "?" }.joined(separator: ",")
      if wanted {
        let group = UUID().uuidString
        for release in work.releases {
          let current = try db.prepare("SELECT payload,active FROM upcoming_releases WHERE id=?")
          SQLiteDatabase.bind(current, 1, release.id)
          let found = sqlite3_step(current) == SQLITE_ROW
          let payload = found ? db.text(current, 0)! : String(decoding: try JSONEncoder().encode(release), as: UTF8.self)
          let active = found ? db.int(current, 1) ?? 0 : 0
          sqlite3_finalize(current)
          let insert = try db.prepare("""
            INSERT INTO upcoming_wants(release_id,group_id,payload,active,added_at) VALUES(?,?,?,?,?)
            ON CONFLICT(release_id) DO NOTHING
            """)
          SQLiteDatabase.bind(insert, 1, release.id)
          SQLiteDatabase.bind(insert, 2, group)
          SQLiteDatabase.bind(insert, 3, payload)
          SQLiteDatabase.bind(insert, 4, active)
          SQLiteDatabase.bind(insert, 5, Int(now.timeIntervalSince1970))
          let status = sqlite3_step(insert)
          sqlite3_finalize(insert)
          guard status == SQLITE_DONE else { throw DatabaseError(message: "保存想看失败") }
        }
      } else {
        // 只操作界面明确列出的原站 ID，旧收藏组不能扩大取消范围。
        for table in ["upcoming_want_changes", "upcoming_wants"] {
          let remove = try db.prepare("DELETE FROM \(table) WHERE release_id IN (\(placeholders))")
          for (i, id) in ids.enumerated() { SQLiteDatabase.bind(remove, Int32(i + 1), id) }
          let status = sqlite3_step(remove)
          sqlite3_finalize(remove)
          guard status == SQLITE_DONE else { throw DatabaseError(message: "取消想看失败") }
        }
      }
      try Task.checkCancellation()
      try db.exec("COMMIT")
      committed = true
    }
  }

  /// 只在来源完整替换事务内调用；失败／取消一并回滚，来源关闭不调用。
  static func recordSnapshot(_ rows: [UpcomingRelease], source: UpcomingSource, at now: Date, db: SQLiteDatabase) throws {
    let incoming = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let stmt = try db.prepare("SELECT release_id,payload,active FROM upcoming_wants WHERE json_extract(payload,'$.source')=?")
    defer { sqlite3_finalize(stmt) }
    SQLiteDatabase.bind(stmt, 1, source.rawValue)
    var previous: [(String, String, Bool)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      previous.append((db.text(stmt, 0)!, db.text(stmt, 1)!, db.int(stmt, 2) == 1))
    }
    for (id, oldPayload, wasActive) in previous {
      try Task.checkCancellation()
      let before = try JSONDecoder().decode(UpcomingRelease.self, from: Data(oldPayload.utf8))
      let after = incoming[id]
      var reason: String?
      if after == nil && wasActive { reason = "移出片单" }
      if let after {
        if !wasActive { reason = "恢复片单" }
        else if before.releaseDate != after.releaseDate {
          reason = after.releaseDate == nil ? "撤回日期" : (before.releaseDate == nil ? "公布日期" : "调整日期")
        } else if before.releaseTime != after.releaseTime {
          reason = after.releaseTime == nil ? "撤回时刻" : (before.releaseTime == nil ? "公布时刻" : "调整时刻")
        }
      }
      let newPayload = try after.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
      if let reason {
        let change = try db.prepare("""
          INSERT INTO upcoming_want_changes(release_id,reason,before_payload,after_payload,observed_at) VALUES(?,?,?,?,?)
          """)
        SQLiteDatabase.bind(change, 1, id)
        SQLiteDatabase.bind(change, 2, reason)
        SQLiteDatabase.bind(change, 3, oldPayload)
        SQLiteDatabase.bind(change, 4, newPayload)
        SQLiteDatabase.bind(change, 5, Int(now.timeIntervalSince1970))
        let status = sqlite3_step(change)
        sqlite3_finalize(change)
        guard status == SQLITE_DONE else { throw DatabaseError(message: "排期变动保存失败") }
      }
      let update = try db.prepare("UPDATE upcoming_wants SET payload=?,active=? WHERE release_id=?")
      SQLiteDatabase.bind(update, 1, newPayload ?? oldPayload)
      SQLiteDatabase.bind(update, 2, after == nil ? 0 : 1)
      SQLiteDatabase.bind(update, 3, id)
      let status = sqlite3_step(update)
      sqlite3_finalize(update)
      guard status == SQLITE_DONE else { throw DatabaseError(message: "想看排期更新失败") }
    }
    let cleanup = try db.prepare("DELETE FROM upcoming_want_changes WHERE observed_at < ?")
    SQLiteDatabase.bind(cleanup, 1, Int(now.timeIntervalSince1970) - 90 * 86400)
    let status = sqlite3_step(cleanup)
    sqlite3_finalize(cleanup)
    guard status == SQLITE_DONE else { throw DatabaseError(message: "排期变动清理失败") }
  }

  /// 各地区的周一至下周一；只比较自然日，不把美区未知时刻转换为北京时间。
  public static func weekBounds(at now: Date, region: String) -> (start: String, end: String) {
    let calendar = UpcomingDate.calendar(region: region)
    let offset = (calendar.component(.weekday, from: now) + 5) % 7
    let start = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
    let end = calendar.date(byAdding: .day, value: 7, to: start)!
    return (UpcomingDate.day(start, region: region), UpcomingDate.day(end, region: region))
  }

  // 当前片单优先；已移除作品使用收藏快照，不丢失最后排期与原站身份。
  private static let catalogSQL = """
    SELECT id AS release_id,payload,active FROM upcoming_releases WHERE active=1
    UNION ALL
    SELECT release_id,payload,active FROM upcoming_wants w
      WHERE NOT EXISTS(SELECT 1 FROM upcoming_releases r WHERE r.id=w.release_id AND r.active=1)
    """

  private static func groupingJSON(sources: [UpcomingSource], externalEnabled: Bool, db: SQLiteDatabase) throws -> String {
    let stmt = try db.prepare("SELECT payload FROM (" + catalogSQL + ") WHERE json_extract(payload,'$.source') IN (" + sources.map { _ in "?" }.joined(separator: ",") + ")")
    defer { sqlite3_finalize(stmt) }
    for (i, source) in sources.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), source.rawValue) }
    var rows: [UpcomingRelease] = []
    while true {
      let status = sqlite3_step(stmt)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW, let payload = db.text(stmt, 0) else { throw DatabaseError(message: "想看归并读取失败") }
      rows.append(try JSONDecoder().decode(UpcomingRelease.self, from: Data(payload.utf8)))
    }
    let connections = try WorkConnectionStore.connections(for: rows, externalEnabled: externalEnabled, db: db)
    let keys = try UpcomingGrouping.keys(rows: rows, connections: connections)
    return String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
  }

  private static func query(mode: UpcomingBrowseMode, sources: [UpcomingSource], region: String?,
                            kind: String?, now: Date, unreadOnly: Bool, groupingJSON: String) -> (sql: String, values: [String], selection: String, ordering: String) {
    var values = ["CN", "US"].flatMap { region in
      let week = Self.weekBounds(at: now, region: region)
      return [UpcomingDate.day(now, region: region), week.start, week.end]
    }
    values.append(groupingJSON)
    var conditions = ["json_extract(payload,'$.source') IN (\(sources.map { _ in "?" }.joined(separator: ",")))"]
    values += sources.map(\.rawValue)
    if let region { conditions.append("json_extract(payload,'$.region')=?"); values.append(region) }
    if let kind { conditions.append("json_extract(payload,'$.kind')=?"); values.append(kind) }
    let weekCondition = "wanted=1 AND active=1 AND json_extract(payload,'$.releaseDate')>=week_start AND json_extract(payload,'$.releaseDate')<week_end"
    let periodCondition = mode == .today ? "wanted=1 AND active=1 AND json_extract(payload,'$.releaseDate')=today" : weekCondition
    let anchor = (mode == .week || mode == .today)
      ? "MIN(CASE WHEN \(periodCondition) THEN json_extract(payload,'$.releaseDate') END)"
      : "COALESCE(MIN(CASE WHEN wanted=1 AND json_extract(payload,'$.releaseDate')>=today THEN json_extract(payload,'$.releaseDate') END),MAX(CASE WHEN wanted=1 THEN json_extract(payload,'$.releaseDate') END))"
    let selection = (mode == .week || mode == .today) ? "anchor IS NOT NULL" : (mode == .changes ? "changed_at IS NOT NULL" : "1")
    let ordering = mode == .changes ? "changed_at DESC,group_id" : "anchor IS NULL,anchor,group_id"
    let sql = """
        WITH calendar(region,today,week_start,week_end) AS (VALUES ('CN',?,?,?),('US',?,?,?)),
        catalog AS (\(catalogSQL)),
        work_keys AS (SELECT key AS release_id,value AS group_id FROM json_each(?)),
        base AS (
          SELECT catalog.*,work_keys.group_id,today,week_start,week_end,
            EXISTS(SELECT 1 FROM upcoming_wants w WHERE w.release_id=catalog.release_id) AS wanted
          FROM catalog JOIN work_keys USING(release_id) JOIN calendar
            ON calendar.region=CASE WHEN json_extract(payload,'$.region')='US' THEN 'US' ELSE 'CN' END
          WHERE \(conditions.joined(separator: " AND "))
        ), grouped AS (
          SELECT group_id,\(anchor) AS anchor,
            MAX((SELECT MAX(observed_at) FROM upcoming_want_changes c WHERE c.release_id=base.release_id
              AND (\(unreadOnly ? "NOT EXISTS (SELECT 1 FROM upcoming_change_reads r WHERE r.change_id=c.id)" : "1"))
              AND c.observed_at>=\(Int(now.timeIntervalSince1970) - 90 * 86400))) AS changed_at
          FROM base GROUP BY group_id HAVING MAX(wanted)=1
        )
      """
    return (sql, values, selection, ordering)
  }

  public func works(mode: UpcomingBrowseMode, sources: [UpcomingSource], region: String? = nil,
                    kind: String? = nil, externalEnabled: Bool = false, now: Date = .now, unreadOnly: Bool = false, offset: Int = 0, limit: Int = 60) async throws -> [UpcomingWork] {
    guard !sources.isEmpty else { return [] }
    return try await queue.run { db in
      let keys = try Self.groupingJSON(sources: sources, externalEnabled: externalEnabled, db: db)
      let query = Self.query(mode: mode, sources: sources, region: region, kind: kind, now: now, unreadOnly: unreadOnly, groupingJSON: keys)
      let values = query.values
      let stmt = try db.prepare("""
        \(query.sql), selected AS (
          SELECT * FROM grouped WHERE \(query.selection) ORDER BY \(query.ordering) LIMIT ? OFFSET ?
        )
        SELECT selected.group_id,selected.anchor,base.payload FROM selected JOIN base USING(group_id)
        ORDER BY \(mode == .changes ? "selected.changed_at DESC," : "")selected.anchor IS NULL,selected.anchor,selected.group_id,base.release_id
        """)
      defer { sqlite3_finalize(stmt) }
      for (i, value) in values.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), value) }
      SQLiteDatabase.bind(stmt, Int32(values.count + 1), max(1, min(60, limit)))
      SQLiteDatabase.bind(stmt, Int32(values.count + 2), max(0, offset))
      var ids: [String] = []
      var dates: [String: String] = [:]
      var releases: [String: [UpcomingRelease]] = [:]
      while sqlite3_step(stmt) == SQLITE_ROW {
        let id = db.text(stmt, 0)!
        if releases[id] == nil { ids.append(id) }
        dates[id] = db.text(stmt, 1)
        releases[id, default: []].append(try JSONDecoder().decode(UpcomingRelease.self, from: Data(db.text(stmt, 2)!.utf8)))
      }
      return ids.map { UpcomingWork(id: "wanted|" + $0, releaseDate: dates[$0], releases: releases[$0]!) }
    }
  }

  /// 计数与列表使用同一分组查询，按作品统计且不受分页截断。
  public func count(mode: UpcomingBrowseMode, sources: [UpcomingSource], region: String? = nil,
                    kind: String? = nil, externalEnabled: Bool = false, now: Date = .now, unreadOnly: Bool = false) async throws -> Int {
    guard !sources.isEmpty else { return 0 }
    return try await queue.run { db in
      let keys = try Self.groupingJSON(sources: sources, externalEnabled: externalEnabled, db: db)
      let query = Self.query(mode: mode, sources: sources, region: region, kind: kind, now: now, unreadOnly: unreadOnly, groupingJSON: keys)
      let stmt = try db.prepare(query.sql + " SELECT COUNT(*) FROM grouped WHERE " + query.selection)
      defer { sqlite3_finalize(stmt) }
      for (i, value) in query.values.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), value) }
      guard sqlite3_step(stmt) == SQLITE_ROW else { throw DatabaseError(message: "关注动态计数失败") }
      return db.int(stmt, 0) ?? 0
    }
  }

  /// 只确认实际展示的事件，不能吞掉读取之后同步新插入的变化。
  public func markRead(changeIDs: [Int]) async throws {
    guard !changeIDs.isEmpty else { return }
    try await queue.run { db in
      let stmt = try db.prepare("INSERT OR IGNORE INTO upcoming_change_reads SELECT id FROM upcoming_want_changes WHERE id IN (" + changeIDs.map { _ in "?" }.joined(separator: ",") + ")")
      defer { sqlite3_finalize(stmt) }
      for (i, id) in changeIDs.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), id) }
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError(message: "标记排期已读失败") }
    }
  }

  public func hasUnread(for ids: [String], now: Date = .now) async throws -> Bool {
    guard !ids.isEmpty else { return false }
    return try await queue.run { db in
      let stmt = try db.prepare("SELECT 1 FROM upcoming_want_changes c WHERE release_id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ") AND observed_at>=? AND NOT EXISTS(SELECT 1 FROM upcoming_change_reads r WHERE r.change_id=c.id) LIMIT 1")
      defer { sqlite3_finalize(stmt) }
      for (i, id) in ids.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), id) }
      SQLiteDatabase.bind(stmt, Int32(ids.count + 1), Int(now.timeIntervalSince1970) - 90 * 86400)
      let status = sqlite3_step(stmt)
      guard status == SQLITE_ROW || status == SQLITE_DONE else { throw DatabaseError(message: "未读排期读取失败") }
      return status == SQLITE_ROW
    }
  }

  public func inactiveIDs(for ids: [String]) async throws -> Set<String> {
    guard !ids.isEmpty else { return [] }
    return try await queue.run { db in
      let stmt = try db.prepare("SELECT release_id FROM upcoming_wants WHERE active=0 AND release_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
      defer { sqlite3_finalize(stmt) }
      for (i, id) in ids.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), id) }
      var result = Set<String>()
      while sqlite3_step(stmt) == SQLITE_ROW { if let id = db.text(stmt, 0) { result.insert(id) } }
      return result
    }
  }

  public func changes(for ids: [String], now: Date = .now) async throws -> [UpcomingWantChange] {
    guard !ids.isEmpty else { return [] }
    return try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT id,release_id,reason,before_payload,after_payload,observed_at,
          EXISTS(SELECT 1 FROM upcoming_change_reads r WHERE r.change_id=id) FROM (
          SELECT *,ROW_NUMBER() OVER(PARTITION BY release_id ORDER BY EXISTS(SELECT 1 FROM upcoming_change_reads r WHERE r.change_id=upcoming_want_changes.id),observed_at DESC,id DESC) AS position
          FROM upcoming_want_changes WHERE release_id IN (\(ids.map { _ in "?" }.joined(separator: ","))) AND observed_at>=?
        ) WHERE position<=10 ORDER BY 7,observed_at DESC,id DESC
        """)
      defer { sqlite3_finalize(stmt) }
      for (i, id) in ids.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), id) }
      SQLiteDatabase.bind(stmt, Int32(ids.count + 1), Int(now.timeIntervalSince1970) - 90 * 86400)
      var result: [UpcomingWantChange] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let before = try JSONDecoder().decode(UpcomingRelease.self, from: Data(db.text(stmt, 3)!.utf8))
        let after = try db.text(stmt, 4).map { try JSONDecoder().decode(UpcomingRelease.self, from: Data($0.utf8)) }
        result.append(UpcomingWantChange(id: db.int(stmt, 0)!, releaseID: db.text(stmt, 1)!, reason: db.text(stmt, 2)!,
          before: before, after: after, observedAt: Date(timeIntervalSince1970: Double(db.int(stmt, 5)!)), isRead: db.int(stmt, 6) == 1))
      }
      return result
    }
  }
}
