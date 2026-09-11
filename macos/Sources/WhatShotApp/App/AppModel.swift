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
  public private(set) var lastError: String?

  private var syncTask: Task<Void, Never>?

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
    defer { syncing = false }
    let engine = SyncEngine(
      client: ButaiClient(settings: settings),
      repo: repo,
      settings: settings
    )
    let summary = await engine.run()
    lastSummary = summary
    if let error = summary.error { lastError = error }
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