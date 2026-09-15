import Foundation
import Observation
import WhatShotCore

/// 应用共享模型：设置、数据库、同步引擎与定时器编排。
/// 平时零定时器空转：同步只在到期或手动触发时短促运行。
@Observable
@MainActor
public final class AppModel {
  public private(set) var settings: ButaiSettings
  let settingsStore: SettingsStore
  public private(set) var queue: DatabaseQueue?
  public private(set) var repo: VideoRepository?

  public private(set) var syncing = false
  public private(set) var lastSummary: SyncSummary?
  /// 最近一次同步结束时间（相对时间"X 分钟前"随它演进）
  public private(set) var lastSyncFinishedAt: Date?
  /// 仅严重错误（failed：一条数据都没拿到）才置位，顶栏红色提示
  public private(set) var lastError: String?
  /// warning 级问题（主数据成功，部分步骤失败如豆瓣 403），顶栏琥珀提示
  public private(set) var lastWarning: String?

  private var syncTask: Task<Void, Never>?
  /// 域名择优器：跨同步轮次保持冠军记忆
  private let domainSelector = DomainSelector()
  /// 最近一次探活结果（当前域名+延迟），供设置页展示
  public private(set) var currentProbe: DomainProbe?
  /// 最近一次发布页自动发现的域名列表（nil = 发布页不可达用了兜底池），供设置页展示
  public private(set) var lastPublishedDomains: [String]?

  /// AppDelegate 启动收尾 + 定时同步（后台静默）
  static func sharedBootstrap() async {
    await SharedRuntime.shared.bootstrapIfNeeded()
    await SharedRuntime.shared.scheduleNextRun()
  }

  init() {
    let store = SettingsStore()
    settingsStore = store
    settings = store.load()
    SharedRuntime.shared.attach(model: self)
  }

  /// 首次渲染时建立数据库连接
  func bootstrapIfNeeded() async {
    guard queue == nil else { return }
    do {
      let path = SharedRuntime.databasePath()
      let newQueue = try await DatabaseQueue(path: path)
      queue = newQueue
      repo = VideoRepository(queue: newQueue)
      try await repo?.recoverInterruptedRuns(at: Date())
      // 启动后台同步：距上次同步超过间隔才跑
      await maybeSync(force: false)
      await scheduleNextRun()
    } catch {
      lastError = "数据库初始化失败：\(error.localizedDescription)"
    }
  }

  /// 手动触发同步
  func syncNow() async {
    await maybeSync(force: true)
  }

  func maybeSync(force: Bool) async {
    guard !syncing, let repo = repo else { return }
    if !force {
      // 未到间隔则跳过：读取最近一次成功同步时间
      if let lastRun = (try? await repo.lastSuccessfulSync()) ?? nil,
         Date().timeIntervalSince(lastRun) < Double(settings.syncIntervalHours) * 3600 {
        return
      }
    }
    syncing = true
    lastError = nil
    lastWarning = nil
    defer { syncing = false }
    // 域名择优：先抓发布页自动发现官方域名（失败静默回落内置兜底池），
    // 再探活选当前最优路由（冠军快路径，全池降级），全池不可达才报错
    let published = await DomainPool.fetchPublishedDomains()
    lastPublishedDomains = published // nil = 发布页不可达，设置页展示兜底池状态
    let candidates = DomainPool.candidates(customBaseURL: settings.baseURL, published: published)
    // 手动钉住的域名跳过探活直接用（临时偏好）；探活一次确认可达后仍注入 selector，
    // 同步中失败走既有自动降级回池，不永久锁死
    var probe: DomainProbe?
    if let pinned = settings.pinnedDomain, candidates.contains(pinned) {
      probe = await domainSelector.probePinned(pinned)
    }
    if probe == nil {
      probe = await domainSelector.pickBest(candidates: candidates)
    }
    guard let probe else {
      lastError = "全部站点域名不可达，请检查网络或稍后重试"
      lastSummary = SyncSummary(status: .failed, fetchedCount: 0, changedCount: 0, detailCount: 0,
                                durationSeconds: 0, error: lastError)
      return
    }
    currentProbe = probe
    // TMDB 补全可选：配了 key 才注入（一期例外扩大，2026-09-15）；豆瓣 403 退避期补有 IMDb 的欧美剧集
    let tmdb = settings.tmdbApiKey.map { TmdbClient(apiKey: $0) }
    let engine = SyncEngine(
      client: ButaiClient(baseURL: probe.baseURL),
      repo: repo,
      settings: settings,
      selector: domainSelector,
      douban: DoubanClient(), // 独立限频器，与 butai0 各自计数
      tmdb: tmdb
    )
    let summary = await engine.run()
    lastSummary = summary
    lastSyncFinishedAt = Date()
    // failed 才是红色错误；warning（主数据成功，部分步骤失败）走琥珀提示，hover 看详情
    if summary.status == .failed {
      lastError = summary.error
    } else if let warning = summary.error {
      lastWarning = warning
    }
  }

  /// 挂载下一次定时同步：短促任务跑完即静默，不用长驻 timer 轮询
  func scheduleNextRun() async {
    syncTask?.cancel()
    guard settings.syncIntervalHours > 0 else { return }
    let interval = Double(settings.syncIntervalHours) * 3600
    syncTask = Task.detached(priority: .background) { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.maybeSync(force: true)
      await self?.scheduleNextRun()
    }
  }

  /// 保存设置：立即生效；间隔变更后重排任务
  func updateSettings(_ newSettings: ButaiSettings) async {
    settings = newSettings
    settingsStore.save(newSettings)
    await scheduleNextRun()
  }
}

/// 进程级共享运行时：数据库路径与跨场景共享
@MainActor
final class SharedRuntime {
  static let shared = SharedRuntime()
  private var model: AppModel?

  static func databasePath() -> String {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WhatShot", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("whatshot.sqlite3").path
  }

  func attach(model: AppModel) {
    self.model = model
  }

  func bootstrapIfNeeded() async {
    await model?.bootstrapIfNeeded()
  }

  func scheduleNextRun() async {
    await model?.scheduleNextRun()
  }
}