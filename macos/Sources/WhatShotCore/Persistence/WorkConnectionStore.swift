import Foundation
import SQLite3

/// 小规模待播身份缓存与只读作品联动，不写主片库，不做本地标题猜测。
public struct WorkConnectionStore: Sendable {
  let queue: DatabaseQueue
  public init(queue: DatabaseQueue) { self.queue = queue }

  public struct CachedLocalization: Sendable {
    public let fingerprint: String
    public let value: UpcomingLocalization
    public let checkedAt: Date
  }

  public func localizations() async throws -> [String: CachedLocalization] {
    try await queue.run { db in try Self.localizations(db: db) }
  }

  private static func localizations(db: SQLiteDatabase) throws -> [String: CachedLocalization] {
    let stmt = try db.prepare("SELECT release_id,fingerprint,payload,checked_at FROM upcoming_localizations")
    defer { sqlite3_finalize(stmt) }
    var result: [String: CachedLocalization] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let id = db.text(stmt, 0), let fingerprint = db.text(stmt, 1), let payload = db.text(stmt, 2),
            let value = try? JSONDecoder().decode(UpcomingLocalization.self, from: Data(payload.utf8)) else { continue }
      result[id] = CachedLocalization(fingerprint: fingerprint, value: value,
        checkedAt: Date(timeIntervalSince1970: Double(db.int(stmt, 3) ?? 0)))
    }
    return result
  }

  public func saveLocalization(_ value: UpcomingLocalization, for row: UpcomingRelease, at now: Date) async throws {
    let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    try await queue.run { db in
      let stmt = try db.prepare("""
        INSERT INTO upcoming_localizations (release_id,fingerprint,payload,checked_at) VALUES (?,?,?,?)
        ON CONFLICT(release_id) DO UPDATE SET fingerprint=excluded.fingerprint,payload=excluded.payload,checked_at=excluded.checked_at
        """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, row.id)
      SQLiteDatabase.bind(stmt, 2, row.identityFingerprint)
      SQLiteDatabase.bind(stmt, 3, payload)
      SQLiteDatabase.bind(stmt, 4, Int(now.timeIntervalSince1970))
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError(message: "片名缓存保存失败") }
    }
  }

  public func activeReleases(sources: [UpcomingSource]) async throws -> [UpcomingRelease] {
    guard !sources.isEmpty else { return [] }
    return try await queue.run { db in try Self.activeReleases(sources: sources, db: db) }
  }

  static func activeReleases(sources: [UpcomingSource], db: SQLiteDatabase) throws -> [UpcomingRelease] {
    let stmt = try db.prepare("SELECT payload FROM upcoming_releases WHERE active=1 AND source IN (\(sources.map { _ in "?" }.joined(separator: ",")))")
    defer { sqlite3_finalize(stmt) }
    for (i, source) in sources.enumerated() { SQLiteDatabase.bind(stmt, Int32(i + 1), source.rawValue) }
    var result: [UpcomingRelease] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = db.text(stmt, 0) else { continue }
      result.append(try JSONDecoder().decode(UpcomingRelease.self, from: Data(payload.utf8)))
    }
    return result
  }

  private struct ExternalIdentity: Sendable {
    var id: String
    var kind: String
    var title: String
    var videoIDs: Set<Int>
    var detail: WhatsNewClient.MediaDetail
  }

  /// 一页统一读取缓存；同原站 ID 多身份、IMDb 指向多条片库记录时不自动关联。
  public func connections(for rows: [UpcomingRelease], externalEnabled: Bool) async throws -> [String: WorkConnection] {
    guard !rows.isEmpty else { return [:] }
    return try await queue.run { db in
      try Self.connections(for: rows, externalEnabled: externalEnabled, db: db)
    }
  }

  static func connections(for rows: [UpcomingRelease], externalEnabled: Bool, db: SQLiteDatabase) throws -> [String: WorkConnection] {
    let metadata = try localizations(db: db)
    var external: [String: ExternalIdentity] = [:]
    if externalEnabled {
      let stmt = try db.prepare("""
        SELECT e.media_id,e.media_type,e.media_title,e.video_id,d.detail_json FROM external_heat e
        JOIN external_media_details d ON d.media_id=e.media_id
        GROUP BY e.media_id,e.media_type,e.media_title,e.video_id
        """)
      defer { sqlite3_finalize(stmt) }
      while sqlite3_step(stmt) == SQLITE_ROW {
        guard let id = db.text(stmt, 0), let kind = db.text(stmt, 1), let payload = db.text(stmt, 4),
              let detail = try? JSONDecoder().decode(WhatsNewClient.MediaDetail.self, from: Data(payload.utf8)) else { continue }
        if external[id] == nil {
          external[id] = ExternalIdentity(id: id, kind: kind, title: db.text(stmt, 2) ?? "", videoIDs: [], detail: detail)
        }
        if let video = db.int(stmt, 3) { external[id]?.videoIDs.insert(video) }
      }
    }
    var result: [String: WorkConnection] = [:]
    for row in rows {
      let cached = metadata[row.id].flatMap { $0.fingerprint == row.identityFingerprint ? $0.value : nil }
      let sourceHits = external.values.filter { item in
        item.kind == row.kind && item.detail.sourceRefs.contains {
          $0.source == row.source.rawValue && $0.sourceId == "\(row.source.rawValue)-\(row.sourceID)"
        }
      }
      guard sourceHits.count <= 1 else { continue }
      if let imdb = cached?.imdbID, let externalIMDb = sourceHits.first?.detail.imdbId,
         imdb.lowercased() != externalIMDb.lowercased() { continue }
      let hits = external.values.filter { item in
        guard item.kind == row.kind else { return false }
        if let imdb = cached?.imdbID, let externalIMDb = item.detail.imdbId,
           externalIMDb.lowercased() != imdb.lowercased() { return false }
        if let imdb = cached?.imdbID, item.detail.imdbId?.lowercased() == imdb.lowercased() { return true }
        if let tmdb = cached?.tmdbID, item.detail.sourceRefs.contains(where: {
          $0.source == "tmdb" && $0.sourceId == "tmdb-movie-\(tmdb)"
        }) { return true }
        return item.detail.sourceRefs.contains {
          $0.source == row.source.rawValue && $0.sourceId == "\(row.source.rawValue)-\(row.sourceID)"
        }
      }
      guard hits.count <= 1 else { continue }
      let hit = hits.first
      var videos = hit?.videoIDs ?? []
      if let imdb = cached?.imdbID {
        let stmt = try db.prepare("SELECT id FROM videos WHERE LOWER(imdb_number)=? AND kind=?")
        SQLiteDatabase.bind(stmt, 1, imdb.lowercased())
        SQLiteDatabase.bind(stmt, 2, row.kind == "movie" ? 1 : 2)
        while sqlite3_step(stmt) == SQLITE_ROW { if let id = db.int(stmt, 0) { videos.insert(id) } }
        sqlite3_finalize(stmt)
      }
      guard videos.count <= 1 else { continue }
      var verifiedIDs: [String: String] = [:]
      if let id = cached?.imdbID ?? hit?.detail.imdbId,
         id.range(of: "^tt[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
        verifiedIDs["imdb"] = id.lowercased()
      }
      let tmdbIDs = Set((hit?.detail.sourceRefs ?? []).compactMap { ref -> Int? in
        guard ref.source == "tmdb", ref.sourceId.hasPrefix("tmdb-movie-") else { return nil }
        return Int(ref.sourceId.dropFirst("tmdb-movie-".count)).flatMap { $0 > 0 ? $0 : nil }
      } + [cached?.tmdbID].compactMap { $0 })
      guard tmdbIDs.count <= 1 else { continue }
      if let tmdb = tmdbIDs.first { verifiedIDs["tmdb"] = String(tmdb) }
      if let id = hit?.id { verifiedIDs["media"] = id }
      var title = cached?.chineseTitle ?? hit?.title
      var videoID: Int?
      if let id = videos.first {
        let stmt = try db.prepare("SELECT title,imdb_number FROM videos WHERE id=? AND kind=?")
        SQLiteDatabase.bind(stmt, 1, id)
        SQLiteDatabase.bind(stmt, 2, row.kind == "movie" ? 1 : 2)
        if sqlite3_step(stmt) == SQLITE_ROW {
          if let localIMDb = db.text(stmt, 1)?.lowercased(),
             localIMDb.range(of: "^tt[0-9]+$", options: .regularExpression) != nil {
            if let imdb = verifiedIDs["imdb"], imdb != localIMDb {
              sqlite3_finalize(stmt)
              continue
            }
            verifiedIDs["imdb"] = localIMDb
          }
          videoID = id
          verifiedIDs["video"] = String(id)
          if let local = db.text(stmt, 0), WorkConnection.isChinese(local) { title = local }
        }
        sqlite3_finalize(stmt)
      }
      result[row.id] = WorkConnection(videoID: videoID, mediaID: hit?.id,
        chineseTitle: title.flatMap { WorkConnection.isChinese($0) ? $0 : nil },
        basis: cached?.tmdbID != nil ? "TMDB · 原名／年份／导演核验" : (hit == nil ? nil : "原站作品 ID"))
      result[row.id]?.verifiedIDs = verifiedIDs
    }
    return result
  }

  public func releases(forVideo videoID: Int, sources: [UpcomingSource], externalEnabled: Bool) async throws -> [UpcomingRelease] {
    let rows = try await activeReleases(sources: sources)
    let linked = try await connections(for: rows, externalEnabled: externalEnabled)
    return rows.filter { linked[$0.id]?.videoID == videoID }.sorted {
      ($0.releaseDate ?? "9999", $0.releaseTime ?? "99:99", $0.id) < ($1.releaseDate ?? "9999", $1.releaseTime ?? "99:99", $1.id)
    }
  }
}
