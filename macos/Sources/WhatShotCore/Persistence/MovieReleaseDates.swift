import Foundation
import SQLite3

extension VideoRepository {
  /// 启动时归一化存量电影：一个事务，按主键每批最多 200 条，重复执行不会重复写入。
  @discardableResult
  public func normalizeMovieReleaseDates(at now: Date = Date()) async throws -> Int {
    let timestamp = Int(now.timeIntervalSince1970)
    return try await queue.run { db in
      try db.exec("BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { try? db.exec("ROLLBACK") } }
      var lastID = Int.min
      var changed = 0
      while true {
        let statement = try db.prepare("""
          SELECT id FROM videos WHERE id > ? AND (kind = 1 OR premiere_source = 'butai0')
          ORDER BY id LIMIT 200
          """)
        SQLiteDatabase.bind(statement, 1, lastID)
        var ids: [Int] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
          if let id = db.int(statement, 0) { ids.append(id) }
          result = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE else { throw DatabaseError(message: "电影上映日期读取失败") }
        guard let endID = ids.last else { break }
        for id in ids {
          if try normalizeMovieReleaseDate(db, videoID: id, timestamp: timestamp) { changed += 1 }
        }
        lastID = endID
      }
      try db.exec("COMMIT")
      committed = true
      return changed
    }
  }

  /// 在调用方事务内读取合并后的行；按实际分类处理，其他来源日期不动。
  @discardableResult
  func normalizeMovieReleaseDate(_ db: SQLiteDatabase, videoID: Int, timestamp: Int) throws -> Bool {
    let select = try db.prepare("SELECT kind, release_info, premiere_date, premiere_source FROM videos WHERE id = ?")
    defer { sqlite3_finalize(select) }
    SQLiteDatabase.bind(select, 1, videoID)
    guard sqlite3_step(select) == SQLITE_ROW else { throw DatabaseError(message: "电影上映信息读取失败") }
    let kind = db.int(select, 0)
    let previousDate = db.text(select, 2)
    let previousSource = db.text(select, 3)
    guard previousSource == "butai0" || (kind == ButaiKind.movie.rawValue && previousSource == nil && previousDate == nil) else {
      return false
    }
    let date = kind == ButaiKind.movie.rawValue ? MovieReleaseDate.parse(db.text(select, 1)) : nil
    let source = date == nil ? nil : "butai0"
    guard date != previousDate || source != previousSource else { return false }
    let update = try db.prepare("UPDATE videos SET premiere_date = ?, premiere_source = ?, premiere_fetched_at = ? WHERE id = ?")
    defer { sqlite3_finalize(update) }
    SQLiteDatabase.bind(update, 1, date)
    SQLiteDatabase.bind(update, 2, source)
    // 清除误分类电影派生值时，也清除检查时间，避免推迟剧集首播补全。
    SQLiteDatabase.bind(update, 3, kind == ButaiKind.movie.rawValue ? timestamp : nil)
    SQLiteDatabase.bind(update, 4, videoID)
    guard sqlite3_step(update) == SQLITE_DONE else { throw DatabaseError(message: "电影上映日期写入失败") }
    return true
  }
}
