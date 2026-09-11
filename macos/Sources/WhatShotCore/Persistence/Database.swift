import Foundation
import SQLite3

/// SQLite 错误
public struct DatabaseError: Error, Sendable {
  public let message: String
}

/// 轻量 SQLite 封装：系统 sqlite3 C 库，单连接 + WAL，零第三方依赖。
/// 非线程安全，调用方需串行访问（同步器与 UI 查询都经由 DatabaseQueue）。
final class SQLiteDatabase: @unchecked Sendable {
  let handle: OpaquePointer

  init(path: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened = db else {
      let code = sqlite3_errcode(db)
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
      sqlite3_close(db)
      throw DatabaseError(message: "打开数据库失败(\(code)): \(message)")
    }
    handle = opened
    try exec("PRAGMA journal_mode=WAL")
    try exec("PRAGMA synchronous=NORMAL")
  }

  deinit {
    sqlite3_close(handle)
  }

  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "未知错误"
      sqlite3_free(error)
      throw DatabaseError(message: "执行失败: \(message) sql=\(sql.prefix(120))")
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
      let message = String(cString: sqlite3_errmsg(handle))
      throw DatabaseError(message: "语句准备失败: \(message) sql=\(sql.prefix(120))")
    }
    return prepared
  }

  func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return String(cString: sqlite3_column_text(stmt, index))
  }

  func int(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(stmt, index))
  }

  static func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
    if let value = value {
      sqlite3_bind_int64(stmt, index, Int64(value))
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  static func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value = value {
      sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 串行化数据库访问队列，所有读写经由 actor 保证安全
public actor DatabaseQueue {
  private var db: SQLiteDatabase?

  /// 打开数据库并迁移 schema。调用方决定路径（生产为 Application Support，测试为临时目录）
  public init(path: String) throws {
    let database = try SQLiteDatabase(path: path)
    try Schema.migrate(database)
    db = database
  }

  /// 只读检查 schema 是否就绪（测试与启动自检用）
  public var schemaReady: Bool {
    db != nil
  }

  func run<T>(_ body: @escaping (SQLiteDatabase) throws -> T) async throws -> T {
    guard let db = db else { throw DatabaseError(message: "数据库未初始化") }
    return try body(db)
  }
}

/// 表结构与迁移
enum Schema {
  static let ddl = """
  CREATE TABLE IF NOT EXISTS videos (
    id INTEGER PRIMARY KEY,            -- butai0 站点内部 ID
    kind INTEGER NOT NULL,             -- 1 电影 2 剧集
    title TEXT NOT NULL,
    otitle TEXT,
    alias TEXT,
    douban_id INTEGER,
    imdb_number TEXT,
    episode_status TEXT,               -- ejs：更新至X集/全集/空
    episodes TEXT,                     -- 总集数字符串，"0"=未知
    douban_score TEXT,
    imdb_score TEXT,
    poster_url TEXT,
    class_names TEXT,
    production_area TEXT,
    years TEXT,
    release_info TEXT,
    director TEXT,
    performer TEXT,
    abstract TEXT,
    definition TEXT,
    seed_count INTEGER DEFAULT 0,
    netdisk_count INTEGER DEFAULT 0,
    seed_updated_at TEXT,
    source_updated_at TEXT,
    first_seen_at INTEGER NOT NULL,    -- 本地首次入库时间戳
    last_synced_at INTEGER NOT NULL,   -- 最近一次确认时间戳
    last_detail_at INTEGER             -- 最近一次拉详情时间戳
  );
  CREATE INDEX IF NOT EXISTS idx_videos_kind ON videos(kind);
  CREATE INDEX IF NOT EXISTS idx_videos_seed_updated ON videos(seed_updated_at);

  CREATE TABLE IF NOT EXISTS observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id INTEGER NOT NULL REFERENCES videos(id),
    observed_at INTEGER NOT NULL,      -- 观察时间戳
    chart_scope TEXT,                  -- NULL=列表观察，3/4/5=热门榜名次观察
    chart_rank INTEGER,                -- 榜内名次（从 1 开始）
    ejs TEXT,
    seed_count INTEGER,
    netdisk_count INTEGER,
    douban_score TEXT,
    imdb_score TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_obs_video_time ON observations(video_id, observed_at);
  CREATE INDEX IF NOT EXISTS idx_obs_chart ON observations(chart_scope, observed_at, chart_rank);

  CREATE TABLE IF NOT EXISTS sync_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    status TEXT NOT NULL,              -- running/success/failed
    fetched INTEGER,
    changed INTEGER,
    error TEXT
  );

  CREATE TABLE IF NOT EXISTS settings_kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  """

  static func migrate(_ db: SQLiteDatabase) throws {
    try db.exec(ddl)
  }
}