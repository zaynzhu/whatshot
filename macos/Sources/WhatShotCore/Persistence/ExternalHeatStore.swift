import Foundation
import SQLite3

/// 外部热度持久化（2026-09-22 WhatsNew 可选接入）：信号快照 upsert + 连接状态单行。
/// 快照语义：每 (media_id, source, scope, window, entry_key) 一行，最新响应覆盖旧值——
/// 不因本次响应未返回而删除/翻转旧行（trending 有 50 条截断，"未返回"只能解释为
/// "本次范围未覆盖"，不能推断下榜），历史积累由 UNIQUE 覆盖天然封顶。
public struct ExternalHeatStore: Sendable {
  let queue: DatabaseQueue
  /// 复用 VideoRepository 的行读取辅助（同模块 internal）；不经它写库
  private let videoRepo: VideoRepository

  public init(queue: DatabaseQueue) {
    self.queue = queue
    self.videoRepo = VideoRepository(queue: queue)
  }

  // MARK: - 行模型

  /// 写入用：匹配结果 + 信号 + 作品标量
  public struct SignalUpsert: Sendable, Equatable {
    public var signal: WhatsNewClient.Signal
    public var mediaTitle: String
    public var mediaType: String?
    public var posterURL: String?
    public var firstReleaseDate: String?
    public var match: ExternalHeatMatcher.Match?

    public init(signal: WhatsNewClient.Signal, mediaTitle: String, mediaType: String?,
                posterURL: String?, firstReleaseDate: String?, match: ExternalHeatMatcher.Match?) {
      self.signal = signal
      self.mediaTitle = mediaTitle
      self.mediaType = mediaType
      self.posterURL = posterURL
      self.firstReleaseDate = firstReleaseDate
      self.match = match
    }
  }

  /// 展示行：信号 + 匹配的本地条目（nil = 未关联）
  public struct DisplayRow: Sendable, Equatable {
    public var source: String
    public var platform: String?
    public var region: String?
    public var window: String?
    public var rankingScope: String
    public var rankingEntryKey: String
    public var rankingEntryLabel: String?
    public var rank: Int?
    public var previousRank: Int?
    public var rankDelta: Int?
    public var valueLabel: String?
    public var capturedAt: String?
    public var isCurrent: Bool
    public var mediaID: String
    public var mediaTitle: String
    public var mediaType: String?
    public var matchBasis: String?
    public var fetchedAt: Date
    public var video: VideoRepository.VideoRow?
  }

  /// 连接状态（外部热度页与设置卡片展示；区分未配置/首次未取得/正常/不可达/服务不对）
  public struct State: Sendable, Equatable {
    public var lastSuccessAt: Date?
    public var lastStatus: String
    public var lastError: String?
    public var lastSignalCount: Int?
    public var lastMediaCount: Int?

    public init(lastSuccessAt: Date?, lastStatus: String, lastError: String?,
                lastSignalCount: Int?, lastMediaCount: Int?) {
      self.lastSuccessAt = lastSuccessAt
      self.lastStatus = lastStatus
      self.lastError = lastError
      self.lastSignalCount = lastSignalCount
      self.lastMediaCount = lastMediaCount
    }

    /// 面向用户的可解释状态文案（未配置在设置页判断，不在此枚举）
    public var statusText: String {
      switch lastStatus {
      case "ok": return "正常"
      case "unreachable": return "服务不可达"
      case "bad_service": return "不是 WhatsNew 服务"
      case "invalid_response": return "响应解析失败"
      default: return "尚未拉取"
      }
    }
  }

  // MARK: - 写入

  /// 事务 upsert 一批信号（一次成功响应一个事务，整批同 fetched_at）。
  /// 返回实际写入（含覆盖）行数。任一失败整批回滚，旧快照不被半批替换
  @discardableResult
  public func upsertSignals(_ rows: [SignalUpsert], fetchedAt: Date) async throws -> Int {
    guard !rows.isEmpty else { return 0 }
    let nowSeconds = Int(fetchedAt.timeIntervalSince1970)
    return try await queue.run { db in
      try db.exec("BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { try? db.exec("ROLLBACK") } }
      let sql = """
        INSERT INTO external_heat (media_id, source, source_category, platform, region, window,
          ranking_scope, ranking_entry_key, ranking_entry_label, rank, previous_rank, rank_delta,
          value_label, captured_at, is_current, media_title, media_type, poster_url,
          first_release_date, video_id, match_basis, fetched_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(media_id, source, ranking_scope, window, ranking_entry_key) DO UPDATE SET
          source_category=excluded.source_category,
          platform=excluded.platform, region=excluded.region,
          rank=excluded.rank, previous_rank=excluded.previous_rank, rank_delta=excluded.rank_delta,
          value_label=excluded.value_label, captured_at=excluded.captured_at,
          is_current=excluded.is_current,
          media_title=excluded.media_title, media_type=excluded.media_type,
          poster_url=excluded.poster_url, first_release_date=excluded.first_release_date,
          video_id=excluded.video_id, match_basis=excluded.match_basis,
          fetched_at=excluded.fetched_at
        """
      let stmt = try db.prepare(sql)
      defer { sqlite3_finalize(stmt) }
      var written = 0
      for row in rows {
        let signal = row.signal
        SQLiteDatabase.bind(stmt, 1, signal.mediaItemId)
        SQLiteDatabase.bind(stmt, 2, signal.source)
        SQLiteDatabase.bind(stmt, 3, nil as String?) // sourceCategory：trending 未返回，留待扩展
        SQLiteDatabase.bind(stmt, 4, signal.platform)
        SQLiteDatabase.bind(stmt, 5, signal.region)
        SQLiteDatabase.bind(stmt, 6, signal.window ?? "")
        SQLiteDatabase.bind(stmt, 7, signal.rankingScope ?? "overall")
        SQLiteDatabase.bind(stmt, 8, signal.rankingEntryKey ?? "work")
        SQLiteDatabase.bind(stmt, 9, signal.rankingEntryLabel)
        SQLiteDatabase.bind(stmt, 10, signal.rank)
        SQLiteDatabase.bind(stmt, 11, signal.previousRank)
        SQLiteDatabase.bind(stmt, 12, signal.rankDelta)
        SQLiteDatabase.bind(stmt, 13, signal.valueLabel)
        SQLiteDatabase.bind(stmt, 14, signal.capturedAt)
        SQLiteDatabase.bind(stmt, 15, signal.isCurrent ? 1 : 0)
        SQLiteDatabase.bind(stmt, 16, row.mediaTitle)
        SQLiteDatabase.bind(stmt, 17, row.mediaType)
        SQLiteDatabase.bind(stmt, 18, row.posterURL)
        SQLiteDatabase.bind(stmt, 19, row.firstReleaseDate)
        SQLiteDatabase.bind(stmt, 20, row.match?.videoID)
        SQLiteDatabase.bind(stmt, 21, row.match?.basis.rawValue)
        SQLiteDatabase.bind(stmt, 22, nowSeconds)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
          throw DatabaseError(message: "外部热度写入失败: \(String(cString: sqlite3_errmsg(db.handle)))")
        }
        sqlite3_reset(stmt)
        written += 1
      }
      try db.exec("COMMIT")
      committed = true
      return written
    }
  }

  /// 连接状态单行 upsert（id=1）
  public func setState(_ state: State, at date: Date) async throws {
    try await queue.run { db in
      let stmt = try db.prepare("""
        INSERT INTO external_heat_state (id, last_success_at, last_status, last_error,
          last_signal_count, last_media_count)
        VALUES (1,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          last_success_at=excluded.last_success_at, last_status=excluded.last_status,
          last_error=excluded.last_error, last_signal_count=excluded.last_signal_count,
          last_media_count=excluded.last_media_count
        """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, state.lastSuccessAt.map { Int($0.timeIntervalSince1970) })
      SQLiteDatabase.bind(stmt, 2, state.lastStatus)
      SQLiteDatabase.bind(stmt, 3, state.lastError)
      SQLiteDatabase.bind(stmt, 4, state.lastSignalCount)
      SQLiteDatabase.bind(stmt, 5, state.lastMediaCount)
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw DatabaseError(message: "外部热度状态写入失败")
      }
    }
  }

  // MARK: - 查询

  /// 当前视图：is_current=1 全部行，按来源/榜/名次排；LEFT JOIN 本地条目（匹配展示）
  public func displayRows() async throws -> [DisplayRow] {
    try await queue.run { db in
      // videoRow 消费 27 列固定序（见 VideoRepository.videoRow），e 表列在前
      let stmt = try db.prepare("""
        SELECT e.media_id, e.source, e.platform, e.region, e.window, e.ranking_scope,
               e.ranking_entry_key, e.ranking_entry_label, e.rank, e.previous_rank, e.rank_delta,
               e.value_label, e.captured_at, e.is_current, e.media_title, e.media_type,
               e.match_basis, e.fetched_at,
               v.id, v.kind, v.title, v.episode_status, v.episodes, v.seed_count, v.netdisk_count,
               v.douban_score, v.imdb_score, v.poster_url, v.last_synced_at,
               v.otitle, v.alias, v.douban_id, v.imdb_number, v.class_names, v.production_area,
               v.years, v.release_info, v.director, v.performer, v.abstract, v.definition,
               v.seed_updated_at, v.source_updated_at, v.premiere_date, v.premiere_source
        FROM external_heat e
        LEFT JOIN videos v ON v.id = e.video_id
        WHERE e.is_current = 1
        ORDER BY e.source, e.ranking_scope, e.window, e.rank
        """)
      defer { sqlite3_finalize(stmt) }
      var rows: [DisplayRow] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let videoIDColumn: Int32 = 18
        let video: VideoRepository.VideoRow?
        if db.int(stmt, videoIDColumn) != nil {
          video = videoRepo.videoRow(stmt, db, offset: videoIDColumn)
        } else {
          video = nil
        }
        rows.append(DisplayRow(
          source: db.text(stmt, 1) ?? "",
          platform: db.text(stmt, 2),
          region: db.text(stmt, 3),
          window: db.text(stmt, 4),
          rankingScope: db.text(stmt, 5) ?? "overall",
          rankingEntryKey: db.text(stmt, 6) ?? "work",
          rankingEntryLabel: db.text(stmt, 7),
          rank: db.int(stmt, 8),
          previousRank: db.int(stmt, 9),
          rankDelta: db.int(stmt, 10),
          valueLabel: db.text(stmt, 11),
          capturedAt: db.text(stmt, 12),
          isCurrent: (db.int(stmt, 13) ?? 1) == 1,
          mediaID: db.text(stmt, 0) ?? "",
          mediaTitle: db.text(stmt, 14) ?? "",
          mediaType: db.text(stmt, 15),
          matchBasis: db.text(stmt, 16),
          fetchedAt: videoRepo.date(db.int(stmt, 17)),
          video: video
        ))
      }
      return rows
    }
  }

  /// 某本地条目的外部信号（详情浮层区块）
  public func signals(forVideo videoID: Int) async throws -> [DisplayRow] {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT media_id, source, platform, region, window, ranking_scope,
               ranking_entry_key, ranking_entry_label, rank, previous_rank, rank_delta,
               value_label, captured_at, is_current, media_title, media_type,
               match_basis, fetched_at
        FROM external_heat WHERE video_id = ? ORDER BY fetched_at DESC
        """)
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, videoID)
      var rows: [DisplayRow] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(DisplayRow(
          source: db.text(stmt, 1) ?? "",
          platform: db.text(stmt, 2),
          region: db.text(stmt, 3),
          window: db.text(stmt, 4),
          rankingScope: db.text(stmt, 5) ?? "overall",
          rankingEntryKey: db.text(stmt, 6) ?? "work",
          rankingEntryLabel: db.text(stmt, 7),
          rank: db.int(stmt, 8),
          previousRank: db.int(stmt, 9),
          rankDelta: db.int(stmt, 10),
          valueLabel: db.text(stmt, 11),
          capturedAt: db.text(stmt, 12),
          isCurrent: (db.int(stmt, 13) ?? 1) == 1,
          mediaID: db.text(stmt, 0) ?? "",
          mediaTitle: db.text(stmt, 14) ?? "",
          mediaType: db.text(stmt, 15),
          matchBasis: db.text(stmt, 16),
          fetchedAt: videoRepo.date(db.int(stmt, 17)),
          video: nil
        ))
      }
      return rows
    }
  }

  public func state() async throws -> State {
    try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT last_success_at, last_status, last_error, last_signal_count, last_media_count
        FROM external_heat_state WHERE id = 1
        """)
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_step(stmt) == SQLITE_ROW else {
        return State(lastSuccessAt: nil, lastStatus: "never", lastError: nil,
                     lastSignalCount: nil, lastMediaCount: nil)
      }
      return State(
        lastSuccessAt: db.int(stmt, 0).map { videoRepo.date($0) },
        lastStatus: db.text(stmt, 1) ?? "never",
        lastError: db.text(stmt, 2),
        lastSignalCount: db.int(stmt, 3),
        lastMediaCount: db.int(stmt, 4)
      )
    }
  }

  /// 本地身份点查：精确匹配用。只按 WhatsNew 给到的 ID 集合 IN 查询，不全量载入
  /// （8GB 内存约束；SQLite 点查极快且全在本地）。返回 kind/imdb/douban 供匹配器判冲突
  public func localIdentities(imdbs: [String], doubans: [Int]) async throws -> [ExternalHeatMatcher.LocalIdentity] {
    var conditions: [String] = []
    var binds: [SQLiteDatabase.BindValue] = []
    let normalizedImdbs = imdbs.map { ExternalHeatMatcher.normalizedIMDb($0) }.filter { $0.hasPrefix("tt") }
    if !normalizedImdbs.isEmpty {
      let placeholders = normalizedImdbs.map { _ in "?" }.joined(separator: ",")
      conditions.append("LOWER(imdb_number) IN (\(placeholders))")
      binds.append(contentsOf: normalizedImdbs.map { .text($0) })
    }
    if !doubans.isEmpty {
      let placeholders = doubans.map { _ in "?" }.joined(separator: ",")
      conditions.append("douban_id IN (\(placeholders))")
      binds.append(contentsOf: doubans.map { .int($0) })
    }
    guard !conditions.isEmpty else { return [] }
    return try await queue.run { db in
      let stmt = try db.prepare("""
        SELECT id, kind, imdb_number, douban_id FROM videos
        WHERE \(conditions.joined(separator: " OR "))
        """)
      defer { sqlite3_finalize(stmt) }
      for (index, value) in binds.enumerated() {
        switch value {
        case let .text(text): SQLiteDatabase.bind(stmt, Int32(index + 1), text)
        case let .int(int): SQLiteDatabase.bind(stmt, Int32(index + 1), int)
        }
      }
      var identities: [ExternalHeatMatcher.LocalIdentity] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        guard let id = db.int(stmt, 0) else { continue }
        let kind = ButaiKind(rawValue: db.int(stmt, 1) ?? 2) ?? .tvSeries
        identities.append(.init(id: id, kind: kind,
                                imdbNumber: db.text(stmt, 2),
                                doubanId: db.int(stmt, 3)))
      }
      return identities
    }
  }
}

/// SQL 绑定值的小型包装（同类型多绑定用）
extension SQLiteDatabase {
  enum BindValue {
    case text(String)
    case int(Int)
  }
}