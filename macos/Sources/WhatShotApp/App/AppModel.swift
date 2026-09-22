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
  /// 同步进行中的实时阶段（定案七）："拉取本周热门" / "首播日补全 · 已补 5"
  public private(set) var syncPhase: String?
  /// 最近一次同步结束时间（相对时间"X 分钟前"随它演进）
  public private(set) var lastSyncFinishedAt: Date?
  /// 仅严重错误（failed：一条数据都没拿到）才置位，顶栏红色提示
  public private(set) var lastError: String?
  /// warning 级问题（主数据成功，部分步骤失败如豆瓣 403），顶栏琥珀提示
  public private(set) var lastWarning: String?

  /// 追剧未读数（定案七）：水位（上次查看汇总时刻）以来有集数变化的条目数。
  /// 追剧页进入即读（水位推进），同步完成后重算
  public private(set) var watchlistUnread = 0

  private var syncTask: Task<Void, Never>?
  /// 运行中的同步引擎 Task：手动停止 = cancel 它，引擎在步骤边界退出（已提交批次保留）
  private var activeEngineTask: Task<SyncSummary, Never>?
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
    PosterLoader.shared.updateLimit(mb: settings.posterCacheLimitMB) // 缓存上限启动即生效
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

  /// 手动停止（定案七）：cancel 引擎 Task，步骤边界退出——已提交批次保留，
  /// 不中断事务、不留伪成功状态（收尾标 stopped，非 failed/success）
  func stopSync() {
    activeEngineTask?.cancel()
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
    syncPhase = "准备同步"
    defer {
      syncing = false
      syncPhase = nil
      activeEngineTask = nil
    }
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
    // S3 镜像可选（2026-09-18 海报镜像定案）：四项配置齐全才注入；NAS 只做哑存储
    var s3: S3Client?
    if settings.s3MirrorEnabled, let endpoint = settings.s3Endpoint, let bucket = settings.s3Bucket,
       let access = settings.s3AccessKey, let secret = settings.s3SecretKey {
      s3 = S3Client(endpoint: endpoint, bucket: bucket, accessKey: access, secretKey: secret)
    }
    // WhatsNew 外部热度可选（2026-09-22）：显式启用 + 配置了地址才注入——
    // 关闭或未配置时引擎整步跳过，零请求
    var whatsnew: WhatsNewClient?
    if settings.whatsnewEnabled == true,
       let whatsnewURL = settings.whatsnewBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
       !whatsnewURL.isEmpty {
      whatsnew = WhatsNewClient(baseURL: whatsnewURL)
    }
    var engine = SyncEngine(
      client: ButaiClient(baseURL: probe.baseURL),
      repo: repo,
      settings: settings,
      selector: domainSelector,
      douban: DoubanClient(), // 独立限频器，与 butai0 各自计数
      tmdb: tmdb,
      s3: s3,
      whatsnew: whatsnew
    )
    // 实时阶段回调：引擎在同步 Task 上执行，转发主线程展示
    engine.onProgress = { [weak self] label, count in
      Task { @MainActor [weak self] in
        self?.syncPhase = count.map { "\(label) · 已补 \($0)" } ?? label
      }
    }
    // 引擎包内层 Task：手动停止时 cancel 这个句柄
    let engineTask = Task { await engine.run() }
    activeEngineTask = engineTask
    let summary = await engineTask.value
    lastSummary = summary
    lastSyncFinishedAt = Date()
    // failed 才是红色错误；warning（主数据成功，部分步骤失败）走琥珀提示，hover 看详情；
    // stopped 是用户主动停止，不冒充错误也不冒充成功
    if summary.status == .failed {
      lastError = summary.error
    } else if summary.status == .stopped {
      // 顶栏走"已停止"展示；主数据已保留
    } else if let warning = summary.error {
      lastWarning = warning
    }
    await refreshWatchlistUnread()
  }

  // MARK: - 追剧更新汇总（定案七）

  /// 查看水位（上次查看更新汇总的时刻）。UserDefaults 只存本机，符合"数据不上传"红线。
  /// 初始 0 = 最早时刻：安全——汇总口径取 max(水位, 关注时刻)，关注前历史永不上报
  private var watchlistWatermark: Date {
    let ts = UserDefaults.standard.double(forKey: "watchlist.lastViewed")
    return ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
  }

  /// 重算未读数（tab 圆点）。同步完成、进入追剧页后调用
  func refreshWatchlistUnread() async {
    guard let repo else { return }
    let updates = (try? await repo.watchlistUpdates(since: watchlistWatermark)) ?? []
    watchlistUnread = updates.count
  }

  /// 进入追剧页即视为已读：展示当前明细后推进水位
  func markWatchlistViewed() {
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "watchlist.lastViewed")
    watchlistUnread = 0
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

  /// 保存设置：立即生效；间隔变更后重排任务；海报缓存容量立即接入加载器
  func updateSettings(_ newSettings: ButaiSettings) async {
    settings = newSettings
    settingsStore.save(newSettings)
    PosterLoader.shared.updateLimit(mb: newSettings.posterCacheLimitMB)
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