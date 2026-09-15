import Foundation

/// 站点配置：域名可配置（该站域名经常更换），接口路径与公开参数固定
public struct ButaiSettings: Codable, Equatable, Sendable {
  /// 站点基址，例如 https://www.butai0.club ，末尾不带斜杠。
  /// 非空时恒为最高优先（私设域名入口，发布页/兜底池都不含它）
  public var baseURL: String
  /// 手动钉住的官方池域名（发布页列表里选的）。nil = 自动探活择优；
  /// 钉住后跳过探活直接用，同步失败仍走自动降级回池（临时偏好，不等于 baseURL 永久钉死）
  public var pinnedDomain: String?
  /// 同步间隔小时数（0 = 关闭后台自动同步）
  public var syncIntervalHours: Int
  /// 海报磁盘缓存上限 MB（0 = 关闭缓存）
  public var posterCacheLimitMB: Int
  /// 电影列表抓取页数（每页 25 条）
  public var movieListPages: Int
  /// 剧集列表抓取页数（每页 25 条）
  public var tvListPages: Int
  /// TMDB Bearer（v4 read token）。一期例外扩大到第二个外部源（2026-09-15 定案）：
  /// 只补有 IMDb 的剧集分季首播日。nil/空 = 关闭 TMDB 补全。只存本地 settings.json，不进 git。
  public var tmdbApiKey: String?

  public static let `default` = ButaiSettings(
    baseURL: "https://www.butai0.club",
    syncIntervalHours: 6,
    posterCacheLimitMB: 300,
    movieListPages: 3,
    tvListPages: 3,
    tmdbApiKey: nil
  )

  public init(baseURL: String, pinnedDomain: String? = nil, syncIntervalHours: Int, posterCacheLimitMB: Int, movieListPages: Int, tvListPages: Int, tmdbApiKey: String? = nil) {
    self.baseURL = baseURL
    self.pinnedDomain = pinnedDomain
    self.syncIntervalHours = syncIntervalHours
    self.posterCacheLimitMB = posterCacheLimitMB
    self.movieListPages = movieListPages
    self.tvListPages = tvListPages
    self.tmdbApiKey = tmdbApiKey
  }
}

/// 应用级设置存储，JSON 持久化到 Application Support，不进 iCloud 不上传
public struct SettingsStore {
  private let fileURL: URL

  public init(directory: URL? = nil) {
    let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WhatShot", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.fileURL = dir.appendingPathComponent("settings.json")
  }

  public func load() -> ButaiSettings {
    guard let data = try? Data(contentsOf: fileURL) else { return .default }
    return (try? JSONDecoder().decode(ButaiSettings.self, from: data)) ?? .default
  }

  public func save(_ settings: ButaiSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      try? data.write(to: fileURL, options: .atomic)
    }
  }
}

/// 接口调用量约束：同一站点连续请求间隔不低于 2 秒。
/// jitter > 0 时实际间隔 = interval ± 随机抖动（豆瓣用：固定等差节奏是教科书级爬虫
/// 特征，随机化间隔是最便宜的缓解，2026-09-14 红队审查定案）
public actor RateLimiter {
  private let interval: TimeInterval
  private let jitter: TimeInterval
  private var lastRequestAt: Date?

  /// - Parameters:
  ///   - interval: 基准间隔
  ///   - jitter: 随机抖动幅度，实际间隔 = interval ± jitter（0 = 固定间隔）
  public init(interval: TimeInterval = 2.0, jitter: TimeInterval = 0) {
    self.interval = interval
    self.jitter = jitter
  }

  public func waitTurn() async {
    if let last = lastRequestAt {
      let actual = interval + (jitter > 0 ? Double.random(in: -jitter...jitter) : 0)
      let elapsed = Date().timeIntervalSince(last)
      if elapsed < actual {
        let remain = actual - elapsed
        try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
      }
    }
    lastRequestAt = Date()
  }
}