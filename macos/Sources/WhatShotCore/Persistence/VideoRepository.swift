import Foundation
import SQLite3

/// 本地库读写：条目 upsert、历史观察写入与查询
public struct VideoRepository: Sendable {
  let queue: DatabaseQueue

  public init(queue: DatabaseQueue) {
    self.queue = queue
  }

  // MARK: - 写入

  /// upsert 条目并记录观察。返回是否发生了用户关心的变化（ejs/seed/评分）
  /// preserveKind=true 时保留库内已有分类（详情接口的 tp 与站点归类矛盾，不得覆盖列表来源的分类）
  public func upsert(_ video: ButaiVideo, chartScope: ButaiChartScope?, chartRank: Int?, now: Date,
                     preserveKind: Bool = false) async throws -> Bool {
    let changed = try await upsertBatch(
      [(video: video, rank: chartRank)], chartScope: chartScope,
      observedAt: now, preserveKind: preserveKind
    )
    return changed > 0
  }

  /// 事务写入一批条目（一个榜单或一页列表）。整批共享一个观察时间戳（latestChart 按
  /// scope 内 MAX(observed_at) 单秒切片，逐条各取时间跨秒会缺榜）；任一条失败整批回滚，
  /// 旧榜不被半批数据替换。返回发生变化的条数
  public func upsertBatch(_ items: [(video: ButaiVideo, rank: Int?)], chartScope: ButaiChartScope?,
                          observedAt: Date, preserveKind: Bool = false) async throws -> Int {
    guard !items.isEmpty else { return 0 }
    let nowSeconds = Int(observedAt.timeIntervalSince1970)
    let scopeRaw = chartScope?.rawValue
    return try await queue.run { db in
      try db.exec("BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { try? db.exec("ROLLBACK") } }
      var changedCount = 0
      for item in items {
        if try writeEntry(db, video: item.video, scopeRaw: scopeRaw, chartRank: item.rank,
                          nowSeconds: nowSeconds, preserveKind: preserveKind) {
          changedCount += 1
        }
      }
      try db.exec("COMMIT")
      committed = true
      return changedCount
    }
  }

  /// 单条写入：videos upsert + 观察记录。只负责 SQL，须在已开启的事务内调用
  private func writeEntry(_ db: SQLiteDatabase, video: ButaiVideo, scopeRaw: String?, chartRank: Int?,
                          nowSeconds: Int, preserveKind: Bool) throws -> Bool {
    let videoID = video.id
    let seedCount = video.seedCount
    let netdiskCount = video.netdiskCount
    let ejs = video.episodeStatus
    let douban = video.doubanScore
    let imdb = video.imdbScore

    let changed: Bool
    // 1. 读旧值判断是否变化；defer 捕获变量值，禁止复用同一变量挂两个 defer
    let selectStmt = try db.prepare("SELECT episode_status, seed_count, netdisk_count, douban_score, imdb_score FROM videos WHERE id = ?")
    defer { sqlite3_finalize(selectStmt) }
    try resetAndBind(selectStmt, videoID)
    let previous = sqlite3_step(selectStmt) == SQLITE_ROW
    let prevEjs = db.text(selectStmt, 0)
    let prevSeed = db.int(selectStmt, 1)
    let prevWp = db.int(selectStmt, 2)
    let prevDouban = db.text(selectStmt, 3)
    let prevImdb = db.text(selectStmt, 4)

    changed = previous && (prevEjs != ejs || prevSeed != seedCount || prevWp != netdiskCount || prevDouban != douban || prevImdb != imdb)

    // 2. upsert 条目；preserveKind 时分类保留库内值（详情回写场景）
    let kindAssign = preserveKind ? "kind=videos.kind," : "kind=excluded.kind,"
    let upsert = """
      INSERT INTO videos (id, kind, title, otitle, alias, douban_id, imdb_number, episode_status, episodes,
        douban_score, imdb_score, poster_url, class_names, production_area, years, release_info,
        director, performer, abstract, definition, seed_count, netdisk_count, seed_updated_at, source_updated_at,
        first_seen_at, last_synced_at, last_detail_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
      \(kindAssign) title=excluded.title, otitle=excluded.otitle, alias=excluded.alias,
      douban_id=excluded.douban_id, imdb_number=excluded.imdb_number,
      episode_status=COALESCE(NULLIF(excluded.episode_status, ''), videos.episode_status),
      episodes=CASE WHEN excluded.episodes != '0' AND excluded.episodes IS NOT NULL AND excluded.episodes != '' THEN excluded.episodes ELSE videos.episodes END,
      douban_score=CASE WHEN excluded.douban_score IS NOT NULL AND excluded.douban_score != '' AND excluded.douban_score != '0' THEN excluded.douban_score ELSE videos.douban_score END,
      imdb_score=CASE WHEN excluded.imdb_score IS NOT NULL AND excluded.imdb_score != '' AND excluded.imdb_score != '0' THEN excluded.imdb_score ELSE videos.imdb_score END,
      seed_count=CASE WHEN excluded.seed_count > 0 THEN excluded.seed_count ELSE videos.seed_count END,
      netdisk_count=CASE WHEN excluded.netdisk_count > 0 THEN excluded.netdisk_count ELSE videos.netdisk_count END,
      seed_updated_at=COALESCE(excluded.seed_updated_at, videos.seed_updated_at),
      poster_url=COALESCE(excluded.poster_url, videos.poster_url),
      class_names=COALESCE(excluded.class_names, videos.class_names), production_area=COALESCE(excluded.production_area, videos.production_area),
      years=COALESCE(excluded.years, videos.years), release_info=COALESCE(excluded.release_info, videos.release_info), director=COALESCE(excluded.director, videos.director),
      performer=COALESCE(excluded.performer, videos.performer), abstract=COALESCE(excluded.abstract, videos.abstract), definition=COALESCE(NULLIF(excluded.definition, '@'), videos.definition),
      last_synced_at=excluded.last_synced_at
      """
    let upsertStmt = try db.prepare(upsert)
    defer { sqlite3_finalize(upsertStmt) }
    bindVideo(upsertStmt, video, now: nowSeconds)
    guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
      throw DatabaseError(message: "条目写入失败: \(String(cString: sqlite3_errmsg(db.handle)))")
    }

    let obs = """
      INSERT INTO observations (video_id, observed_at, chart_scope, chart_rank, ejs, seed_count, netdisk_count, douban_score, imdb_score)
      VALUES (?,?,?,?,?,?,?,?,?)
      """
    let obsStmt = try db.prepare(obs)
    defer { sqlite3_finalize(obsStmt) }
    SQLiteDatabase.bind(obsStmt, 1, videoID)
    SQLiteDatabase.bind(obsStmt, 2, nowSeconds)
    SQLiteDatabase.bind(obsStmt, 3, scopeRaw)
    SQLiteDatabase.bind(obsStmt, 4, chartRank)
    SQLiteDatabase.bind(obsStmt, 5, ejs)
    SQLiteDatabase.bind(obsStmt, 6, seedCount)
    SQLiteDatabase.bind(obsStmt, 7, netdiskCount)
    SQLiteDatabase.bind(obsStmt, 8, douban)
    SQLiteDatabase.bind(obsStmt, 9, imdb)
    guard sqlite3_step(obsStmt) == SQLITE_DONE else {
      throw DatabaseError(message: "观察写入失败: \(String(cString: sqlite3_errmsg(db.handle)))")
    }
    return changed
  }

  /// 标记条目刚拉过详情
  public func markDetailSynced(videoID: Int, at date: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("UPDATE videos SET last_detail_at = ? WHERE id = ?")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, Int(date.timeIntervalSince1970))
      SQLiteDatabase.bind(stmt, 2, videoID)
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "标记详情时间失败")
      }
    }
  }

  /// 记录一次同步运行，返回 run ID
  public func startSyncRun(at date: Date) async throws -> Int {
    try await queue.run { db in
      let stmt = try db.prepare("INSERT INTO sync_runs (started_at, status) VALUES (?, 'running')")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, Int(date.timeIntervalSince1970))
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "同步记录写入失败")
      }
      return Int(sqlite3_last_insert_rowid(db.handle))
    }
  }

  public func finishSyncRun(id: Int, status: String, fetched: Int, changed: Int, error: String?, at date: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("UPDATE sync_runs SET finished_at=?, status=?, fetched=?, changed=?, error=? WHERE id=?")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, Int(date.timeIntervalSince1970))
      SQLiteDatabase.bind(stmt, 2, status)
      SQLiteDatabase.bind(stmt, 3, fetched)
      SQLiteDatabase.bind(stmt, 4, changed)
      SQLiteDatabase.bind(stmt, 5, error)
      SQLiteDatabase.bind(stmt, 6, id)
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "同步记录收尾失败")
      }
    }
  }

  /// 启动时收尾中断遗留的 running 同步记录（对齐 whatsnew 语义）
  public func recoverInterruptedRuns(at date: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("""
        UPDATE sync_runs SET finished_at=?, status='failed',
          error='同步进程中断，已自动收尾；请重新触发同步'
        WHERE status='running'
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, Int(date.timeIntervalSince1970))
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "中断记录收尾失败")
      }
    }
  }

  // MARK: - 查询

  /// 条目列表排序：默认资源更新（站点"最近更新"），剧集页可切首播日倒序
  public enum ListSort: String, Sendable, CaseIterable {
    case seedUpdated = "资源更新"
    case premiere = "首播时间"
  }

  /// 内容筛选条件（纯本地 WHERE）。nil/空 = 不筛
  public struct ListFilter: Sendable, Equatable {
    public var years: String?          // 年代：复用但ai0 字典档位（2026/近三年/90年代…），本地按 years 数值映射
    public var airingOnly: Bool         // 仅播出中（更新至X集）
    public var classNames: String?      // 类型（单选，class_names 逗号分隔多值 LIKE 匹配）
    public var area: String?           // 地区（production_area LIKE）

    public init(years: String? = nil, airingOnly: Bool = false, classNames: String? = nil, area: String? = nil) {
      self.years = years
      self.airingOnly = airingOnly
      self.classNames = classNames
      self.area = area
    }

    public var isEmpty: Bool {
      years == nil && !airingOnly && classNames == nil && area == nil
    }
  }

  /// 年代档位 → 年份区间映射（对齐但ai0 字典 t3：近三年/2026…2017/20年代…更早）
  static func yearRange(for bucket: String, now: Date = Date()) -> (low: Int, high: Int)? {
    // 1. 特殊档位
    let calendar = Calendar(identifier: .gregorian)
    let currentYear = calendar.component(.year, from: now)
    if bucket == "近三年" { return (currentYear - 2, currentYear) }
    if bucket == "更早" { return (Int.min, 1979) }
    // 2. 「N年代」档位（20年代/10年代/00年代/90年代/80年代），必须先于纯数字解析：
    //    "10年代" 的 prefix(4) 会截出 "10" 被当年份。
    //    世纪归属按字典语义：00/10/20 → 2000+n，80/90 → 1900+n（n≥50 视为上世纪，唯一且稳定）
    if bucket.hasSuffix("年代") {
      let prefix = String(bucket.dropLast(2))
      if let n = Int(prefix), n >= 0, n < 100 {
        let century = n >= 50 ? 1900 : 2000
        return (century + n, century + n + 9)
      }
    }
    // 3. 纯四位年份（2026 → 2026）
    if bucket.count == 4, let y = Int(bucket) { return (y, y) }
    return nil
  }

  /// 列表查询（分页懒加载）。排序与筛选由调用方指定。
  /// 首播排序：日期降序（未来日期照排在前，定案 Q8）；未知日期排尾按资源更新次序（定案 Q7）
  public func listVideos(kind: ButaiKind, limit: Int, offset: Int,
                         sort: ListSort = .seedUpdated, filter: ListFilter = ListFilter()) async throws -> [VideoRow] {
    // WHERE 片段构造
    var conditions: [String] = ["kind = ?"]
    var binds: [Any?] = [kind.rawValue]
    if let years = filter.years, let range = Self.yearRange(for: years) {
      conditions.append("CAST(COALESCE(years, '0') AS INTEGER) BETWEEN ? AND ?")
      binds.append(range.low)
      binds.append(range.high)
    }
    if filter.airingOnly {
      conditions.append("episode_status LIKE '更新至%'")
    }
    if let cls = filter.classNames, !cls.isEmpty {
      conditions.append("(class_names IS ? OR class_names LIKE ? OR class_names LIKE ? OR class_names LIKE ?)")
      binds.append(cls as String?)
      binds.append("\(cls),%")
      binds.append("%,\(cls),%")
      binds.append("%,\(cls)")
    }
    if let area = filter.area, !area.isEmpty {
      conditions.append("production_area LIKE ?")
      binds.append("%\(area)%")
    }
    let whereSQL = conditions.joined(separator: " AND ")
    let orderSQL: String
    switch sort {
    case .seedUpdated:
      orderSQL = "seed_updated_at DESC"
    case .premiere:
      // 首播日倒序；未知排尾，组内按资源更新稳定次序
      orderSQL = "CASE WHEN premiere_date IS NULL THEN 1 ELSE 0 END, premiere_date DESC, seed_updated_at DESC"
    }

    return try await queue.run { db in
      let sql = """
        SELECT id, kind, title, episode_status, episodes, seed_count, netdisk_count, douban_score,
               imdb_score, poster_url, last_synced_at,
               otitle, alias, douban_id, imdb_number, class_names, production_area,
               years, release_info, director, performer, abstract, definition,
               seed_updated_at, source_updated_at, premiere_date
        FROM videos WHERE \(whereSQL) ORDER BY \(orderSQL) LIMIT ? OFFSET ?
      """
      let stmt = try db.prepare(sql)
      defer { sqlite3_finalize(stmt) }
      for (index, value) in binds.enumerated() {
        if let int = value as? Int {
          SQLiteDatabase.bind(stmt, Int32(index + 1), int)
        } else {
          SQLiteDatabase.bind(stmt, Int32(index + 1), value as? String)
        }
      }
      SQLiteDatabase.bind(stmt, Int32(binds.count + 1), limit)
      SQLiteDatabase.bind(stmt, Int32(binds.count + 2), offset)
      var rows: [VideoRow] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(videoRow(stmt, db))
      }
      return rows
    }
  }

  /// 单条详情（含详情字段）
  public func video(id: Int) async throws -> VideoRow? {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT id, kind, title, episode_status, episodes, seed_count, netdisk_count, douban_score,
               imdb_score, poster_url, last_synced_at,
               otitle, alias, douban_id, imdb_number, class_names, production_area,
               years, release_info, director, performer, abstract, definition,
               seed_updated_at, source_updated_at, premiere_date
        FROM videos WHERE id = ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, id)
      guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
      return videoRow(stmt, db)
    }
  }

  /// 单条详情（含详情字段）
  public struct VideoRow: Sendable, Equatable {
    public var id: Int
    public var kind: ButaiKind
    public var title: String
    public var originalTitle: String?
    public var alias: String?
    public var doubanId: Int?
    public var imdbNumber: String?
    public var episodeStatus: String
    public var episodes: String
    public var doubanScore: String?
    public var imdbScore: String?
    public var posterURL: String?
    public var classNames: String?
    public var productionArea: String?
    public var years: String?
    public var releaseInfo: String?
    public var director: String?
    public var performer: String?
    public var abstract: String?
    public var definition: String?
    public var seedCount: Int
    public var netdiskCount: Int
    public var seedUpdatedAt: String?
    public var sourceUpdatedAt: String?
    public var premiereDate: String?
    public var lastSyncedAt: Date
  }

  /// 历史时间线：某条目的按时间观察
  public struct ObservationRow: Sendable, Equatable {
    public var observedAt: Date
    public var chartScope: ButaiChartScope?
    public var chartRank: Int?
    public var ejs: String?
    public var seedCount: Int?
    public var netdiskCount: Int?
    public var doubanScore: String?
    public var imdbScore: String?
  }

  public func observations(videoID: Int, limit: Int = 200) async throws -> [ObservationRow] {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT observed_at, chart_scope, chart_rank, ejs, seed_count, netdisk_count, douban_score, imdb_score
        FROM observations WHERE video_id = ? ORDER BY observed_at DESC LIMIT ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, videoID)
      SQLiteDatabase.bind(stmt, 2, limit)
      var rows: [ObservationRow] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(ObservationRow(
          observedAt: date(db.int(stmt, 0)),
          chartScope: db.text(stmt, 1).flatMap(ButaiChartScope.init(rawValue:)),
          chartRank: db.int(stmt, 2),
          ejs: db.text(stmt, 3),
          seedCount: db.int(stmt, 4),
          netdiskCount: db.int(stmt, 5),
          doubanScore: db.text(stmt, 6),
          imdbScore: db.text(stmt, 7)
        ))
      }
      return rows
    }
  }

  /// 某个榜的最新一次快照（名次排序）
  public func latestChart(_ scope: ButaiChartScope) async throws -> [(rank: Int, video: VideoRow)] {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT o.chart_rank, v.id, v.kind, v.title, v.episode_status, v.episodes, v.seed_count,
               v.netdisk_count, v.douban_score, v.imdb_score, v.poster_url, v.last_synced_at,
               v.otitle, v.alias, v.douban_id, v.imdb_number, v.class_names, v.production_area,
               v.years, v.release_info, v.director, v.performer, v.abstract, v.definition,
               v.seed_updated_at, v.source_updated_at, v.premiere_date
        FROM observations o JOIN videos v ON v.id = o.video_id
        WHERE o.chart_scope = ?
          AND o.observed_at = (SELECT MAX(observed_at) FROM observations WHERE chart_scope = ?)
        ORDER BY o.chart_rank ASC
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, scope.rawValue)
      SQLiteDatabase.bind(stmt, 2, scope.rawValue)
      var rows: [(rank: Int, video: VideoRow)] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let rank = db.int(stmt, 0) ?? 0
        rows.append((rank, videoRow(stmt, db, offset: 1)))
      }
      return rows
    }
  }

  /// 某个榜最新一批观察的时间（分榜单新鲜度）。nil = 该榜还没有任何数据
  public func chartLastUpdated(_ scope: ButaiChartScope) async throws -> Date? {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT MAX(observed_at) FROM observations WHERE chart_scope = ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, scope.rawValue)
      guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
      return date(db.int(stmt, 0))
    }
  }

  /// 名次变化标记。previousRank=nil 表示本次入榜（上一批完整且确实不含该作品，
  /// 不等于历史首次入榜）；delta=上一批名次-本批名次，正数表示上升
  public struct ChartMovement: Sendable, Equatable {
    public let previousRank: Int?
    public let delta: Int?

    public init(previousRank: Int?, delta: Int?) {
      self.previousRank = previousRank
      self.delta = delta
    }
  }

  /// 名次变化标记：比较同 scope 最近两个批次（latestChart 只取最新一批，批次写入
  /// 是原子的，因此比较的两个批次都是完整提交的）。空字典 = 无上一批（首次）或名次全部未变
  public func chartMovements(_ scope: ButaiChartScope) async throws -> [Int: ChartMovement] {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT DISTINCT observed_at FROM observations
        WHERE chart_scope = ? ORDER BY observed_at DESC LIMIT 2
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, scope.rawValue)
      var batches: [Int] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        batches.append(db.int(stmt, 0) ?? 0)
      }
      guard batches.count == 2 else { return [:] } // 首次同步没有基线，不制造任何变化事件
      // 上一批：不含该作品的完整批次才有“本次入榜”依据；上一批空查询不到批次（被裁剪）则不比较
      let previous = try chartRanks(db, scope: scope, observedAt: batches[1])
      guard !previous.isEmpty else { return [:] }
      let current = try chartRanks(db, scope: scope, observedAt: batches[0])
      var movements: [Int: ChartMovement] = [:]
      for (videoID, rank) in current {
        if let prevRank = previous[videoID] {
          let delta = prevRank - rank // 名次上升为正（1→3 名是升）
          if delta != 0 {
            movements[videoID] = ChartMovement(previousRank: prevRank, delta: delta)
          }
        } else {
          movements[videoID] = ChartMovement(previousRank: nil, delta: nil) // 本次入榜：上一批完整且不含此作品
        }
      }
      return movements
    }
  }

  /// 某一批次的 video_id → 名次映射（批次内部 id 唯一，upsertBatch 原子写入保证）
  private func chartRanks(_ db: SQLiteDatabase, scope: ButaiChartScope, observedAt: Int) throws -> [Int: Int] {
    let stmt = try db.prepare("""
      SELECT video_id, chart_rank FROM observations
      WHERE chart_scope = ? AND observed_at = ?
    """)
    defer { sqlite3_finalize(stmt) }
    SQLiteDatabase.bind(stmt, 1, scope.rawValue)
    SQLiteDatabase.bind(stmt, 2, observedAt)
    var ranks: [Int: Int] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let videoID = db.int(stmt, 0), let rank = db.int(stmt, 1) {
        ranks[videoID] = rank
      }
    }
    return ranks
  }

  /// 需要补拉详情的条目：从未拉过详情或详情距上次超过指定小时数，按 seed_updated_at 新到旧。
  /// 返回豆瓣 ID（详情接口的 id 参数是站点 idcode/豆瓣 ID）
  public func detailRefreshCandidates(limit: Int, detailStaleHours: Int) async throws -> [Int] {
    try await queue.run { db in
      let threshold = Int(Date().timeIntervalSince1970) - detailStaleHours * 3600
      let stmt = try db.prepare("""
        SELECT COALESCE(douban_id, 0) FROM videos
        WHERE last_detail_at IS NULL OR last_detail_at < ?
        ORDER BY seed_updated_at DESC LIMIT ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, threshold)
      SQLiteDatabase.bind(stmt, 2, limit)
      var ids: [Int] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        if let id = db.int(stmt, 0), id > 0 { ids.append(id) }
      }
      return ids
    }
  }

  /// 观察历史保留天数裁剪，返回删除行数
  public func pruneObservations(keepDays: Int, now: Date) async throws -> Int {
    try await queue.run { db in
      let cutoff = Int(now.timeIntervalSince1970) - keepDays * 86400
      let stmt = try db.prepare("DELETE FROM observations WHERE observed_at < ?")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, cutoff)
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "历史裁剪失败")
      }
      return Int(sqlite3_changes(db.handle))
    }
  }

  // MARK: - 首播日（豆瓣补全）

  /// 写入首播日。doubanId 定位条目；date 为 YYYY-MM-DD 或 nil（无日期也记录抓取过，避免反复重查）
  public func setPremiereDate(doubanId: Int, date: String?, source: String = "douban", at: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("""
        UPDATE videos SET premiere_date = ?, premiere_source = ?, premiere_fetched_at = ?
        WHERE douban_id = ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, date)
      SQLiteDatabase.bind(stmt, 2, date == nil ? nil : source)
      SQLiteDatabase.bind(stmt, 3, Int(at.timeIntervalSince1970))
      SQLiteDatabase.bind(stmt, 4, doubanId)
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "首播日写入失败")
      }
    }
  }

  /// 待补全首播日的条目：从未抓取，或无日期且距上次抓取超过 recheckHours（豆瓣日期可能后来补上，
  /// 放开地区白名单后需给旧数据重查机会；有日期的条目不重查）。按资源更新新到旧排序，
  /// 积压清偿由调用方按返回数量决定放大上限。
  public func premiereCandidates(limit: Int, recheckHours: Int = 24, now: Date = Date()) async throws -> [Int] {
    let threshold = Int(now.timeIntervalSince1970) - recheckHours * 3600
    return try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT douban_id FROM videos
        WHERE kind = ? AND douban_id IS NOT NULL AND douban_id > 0
          AND (premiere_fetched_at IS NULL
               OR (premiere_date IS NULL AND premiere_fetched_at < ?))
        ORDER BY seed_updated_at DESC LIMIT ?
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, ButaiKind.tvSeries.rawValue)
      SQLiteDatabase.bind(stmt, 2, threshold)
      SQLiteDatabase.bind(stmt, 3, limit)
      var ids: [Int] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        if let id = db.int(stmt, 0) { ids.append(id) }
      }
      return ids
    }
  }

  /// 未补全条目总数（判断积压清偿档位；口径与 premiereCandidates 一致，含到期重查）
  public func premierePendingCount(recheckHours: Int = 24, now: Date = Date()) async throws -> Int {
    let threshold = Int(now.timeIntervalSince1970) - recheckHours * 3600
    return try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT COUNT(*) FROM videos
        WHERE kind = ? AND douban_id IS NOT NULL AND douban_id > 0
          AND (premiere_fetched_at IS NULL
               OR (premiere_date IS NULL AND premiere_fetched_at < ?))
      """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, ButaiKind.tvSeries.rawValue)
      SQLiteDatabase.bind(stmt, 2, threshold)
      guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
      return db.int(stmt, 0) ?? 0
    }
  }

  /// 数据库文件大小字节数
  public func databaseFileSize() async throws -> Int64 {
    try await queue.run { db in
      let stmt = try db.prepare("PRAGMA page_count")
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_step(stmt) == SQLITE_ROW, let pages = db.int(stmt, 0) else { return 0 }
      return Int64(pages) * 4096
    }
  }

  /// 最近一次成功（success 或 warning）同步时间
  public func lastSuccessfulSync() async throws -> Date? {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT MAX(finished_at) FROM sync_runs WHERE status IN ('success','warning')
      """)
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
      return date(db.int(stmt, 0))
    }
  }

  // MARK: - 绑定辅助

  func bindVideo(_ stmt: OpaquePointer, _ video: ButaiVideo, now: Int) {
    SQLiteDatabase.bind(stmt, 1, video.id)
    SQLiteDatabase.bind(stmt, 2, video.kind.rawValue)
    SQLiteDatabase.bind(stmt, 3, video.title)
    SQLiteDatabase.bind(stmt, 4, video.originalTitle)
    SQLiteDatabase.bind(stmt, 5, video.alias)
    SQLiteDatabase.bind(stmt, 6, video.doubanId)
    SQLiteDatabase.bind(stmt, 7, video.imdbNumber)
    SQLiteDatabase.bind(stmt, 8, video.episodeStatus)
    SQLiteDatabase.bind(stmt, 9, video.episodes)
    SQLiteDatabase.bind(stmt, 10, video.doubanScore)
    SQLiteDatabase.bind(stmt, 11, video.imdbScore)
    SQLiteDatabase.bind(stmt, 12, video.posterURL)
    SQLiteDatabase.bind(stmt, 13, video.classNames)
    SQLiteDatabase.bind(stmt, 14, video.productionArea)
    SQLiteDatabase.bind(stmt, 15, video.years)
    SQLiteDatabase.bind(stmt, 16, video.release)
    SQLiteDatabase.bind(stmt, 17, video.director)
    SQLiteDatabase.bind(stmt, 18, video.performer)
    SQLiteDatabase.bind(stmt, 19, video.abstract)
    SQLiteDatabase.bind(stmt, 20, video.definition)
    SQLiteDatabase.bind(stmt, 21, video.seedCount)
    SQLiteDatabase.bind(stmt, 22, video.netdiskCount)
    SQLiteDatabase.bind(stmt, 23, video.seedUpdatedAt)
    SQLiteDatabase.bind(stmt, 24, video.updatedAt)
    SQLiteDatabase.bind(stmt, 25, now)
    SQLiteDatabase.bind(stmt, 26, now)
    SQLiteDatabase.bind(stmt, 27, nil as Int?)
  }

  func resetAndBind(_ stmt: OpaquePointer, _ id: Int) throws {
    sqlite3_reset(stmt)
    SQLiteDatabase.bind(stmt, 1, id)
  }

  func date(_ seconds: Int?) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds ?? 0))
  }

  /// 从当前行读 VideoRow。SELECT 列序固定：
  /// 0 id, 1 kind, 2 title, 3 episode_status, 4 episodes, 5 seed_count, 6 netdisk_count,
  /// 7 douban_score, 8 imdb_score, 9 poster_url, 10 last_synced_at,
  /// 11 otitle, 12 alias, 13 douban_id, 14 imdb_number, 15 class_names, 16 production_area,
  /// 17 years, 18 release_info, 19 director, 20 performer, 21 abstract, 22 definition,
  /// 23 seed_updated_at, 24 source_updated_at, 25 premiere_date
  func videoRow(_ stmt: OpaquePointer, _ db: SQLiteDatabase, offset: Int32 = 0) -> VideoRow {
    VideoRow(
      id: db.int(stmt, offset + 0) ?? 0,
      kind: ButaiKind(rawValue: db.int(stmt, offset + 1) ?? 2) ?? .tvSeries,
      title: db.text(stmt, offset + 2) ?? "",
      originalTitle: db.text(stmt, offset + 11),
      alias: db.text(stmt, offset + 12),
      doubanId: db.int(stmt, offset + 13),
      imdbNumber: db.text(stmt, offset + 14),
      episodeStatus: db.text(stmt, offset + 3) ?? "",
      episodes: db.text(stmt, offset + 4) ?? "",
      doubanScore: db.text(stmt, offset + 7),
      imdbScore: db.text(stmt, offset + 8),
      posterURL: db.text(stmt, offset + 9),
      classNames: db.text(stmt, offset + 15),
      productionArea: db.text(stmt, offset + 16),
      years: db.text(stmt, offset + 17),
      releaseInfo: db.text(stmt, offset + 18),
      director: db.text(stmt, offset + 19),
      performer: db.text(stmt, offset + 20),
      abstract: db.text(stmt, offset + 21),
      definition: db.text(stmt, offset + 22),
      seedCount: db.int(stmt, offset + 5) ?? 0,
      netdiskCount: db.int(stmt, offset + 6) ?? 0,
      seedUpdatedAt: db.text(stmt, offset + 23),
      sourceUpdatedAt: db.text(stmt, offset + 24),
      premiereDate: db.text(stmt, offset + 25),
      lastSyncedAt: date(db.int(stmt, offset + 10))
    )
  }
}
/// SwiftUI sheet(item:) 桥接
extension VideoRepository.VideoRow: Identifiable {}
