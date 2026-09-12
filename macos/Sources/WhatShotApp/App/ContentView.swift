import SwiftUI
import WhatShotCore

/// 主窗口：顶部品牌栏 + 文字式标签切换（琥珀下划线）+ 内容区
/// 同步控制与状态收敛在顶栏右侧，无底部状态栏
struct ContentView: View {
  @Environment(AppModel.self) private var app
  @State private var tab = 0
  @State private var lastSync: Date?

  private let tabs = ["热门榜", "剧集", "电影", "设置"]

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider().overlay(Theme.hairline)

      // 内容区
      ZStack {
        switch tab {
        case 0: ChartTabView()
        case 1: TVTabView()
        case 2: MovieTabView()
        default: SettingsTabView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Theme.bg)
    .preferredColorScheme(.dark)
    // repo 异步初始化：nil→就位 翻转时重跑，避免首屏拿不到上次同步时间
    .task(id: app.repo == nil) { await reloadLastSync() }
    .onChange(of: app.lastSummary) { _, _ in
      Task { await reloadLastSync() }
    }
  }

  private var headerBar: some View {
    HStack(spacing: 22) {
      // 品牌：火焰是全应用唯一的橙色图标（身份锚点）
      HStack(spacing: 6) {
        Image(systemName: "flame.fill")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(Theme.accent)
        Text("WhatShot")
          .font(.system(size: 13.5, weight: .heavy))
          .foregroundStyle(Theme.textPrimary)
      }

      HStack(spacing: 18) {
        ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
          TextTab(title: title, selected: tab == index) {
            withAnimation(.easeOut(duration: 0.15)) { tab = index }
          }
        }
      }

      Spacer()

      // 同步状态区：状态文字 + 同步按钮
      // fixedSize 防挤压：窄窗（台前调度缩放）下压碎的是 tab 文字而非按钮本体
      HStack(spacing: 12) {
        if app.syncing {
          ProgressView()
            .controlSize(.small)
            .tint(Theme.accent)
          Text("同步中…")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
        } else {
          if let error = app.lastError {
            Text("同步出错")
              .font(.system(size: 11))
              .foregroundStyle(.red.opacity(0.9))
              .help(error)
          } else if let lastSync {
            Text("已同步 \(lastSync.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
              .font(.system(size: 10.5).monospacedDigit())
              .foregroundStyle(Theme.textTertiary)
              .help(lastSyncSummary)
          }
          OutlineButton(title: "同步", icon: "arrow.clockwise") {
            Task { await app.syncNow() }
          }
        }
      }
      .fixedSize()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(Theme.bg)
  }

  private var lastSyncSummary: String {
    guard let summary = app.lastSummary else { return "" }
    return "拉取 \(summary.fetchedCount) · 更新 \(summary.changedCount) · 详情 \(summary.detailCount)"
  }

  private func reloadLastSync() async {
    guard let repo = app.repo else { return }
    lastSync = (try? await repo.lastSuccessfulSync()) ?? nil
  }
}
