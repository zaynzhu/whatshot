import SwiftUI
import WhatShotCore

/// 主窗口：顶部品牌栏 + 文字式标签切换（琥珀下划线）+ 内容区
/// 同步控制与状态收敛在顶栏右侧，无底部状态栏
struct ContentView: View {
  @Environment(AppModel.self) private var app
  @State private var tab = 0
  @State private var lastSync: Date?

  private let tabs = ["热门榜", "追剧", "剧集", "电影", "外部热度", "设置"]
  /// 追剧 tab 的下标：未读圆点挂它身上
  private let watchlistTabIndex = 1

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider().overlay(Theme.hairline)

      // 内容区
      ZStack {
        switch tab {
        case 0: ChartTabView()
        case 1: WatchlistTabView()
        case 2: TVTabView()
        case 3: MovieTabView()
        case 4: ExternalHeatTabView()
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
          // 追剧未读圆点（定案七）：有更新时提示，进入追剧页即读
          .overlay(alignment: .topTrailing) {
            if index == watchlistTabIndex, app.watchlistUnread > 0 {
              Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .offset(x: 6, y: -2)
            }
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
          // 实时阶段（定案七）："拉取本周热门" / "首播日补全 · 已补 5"
          Text(app.syncPhase ?? "同步中…")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
          OutlineButton(title: "停止", icon: "xmark") {
            app.stopSync()
          }
        } else {
          if let error = app.lastError {
            statusButton(text: "同步出错", color: .red.opacity(0.9), help: error)
          } else if let warning = app.lastWarning {
            // 琥珀提示带上距上次同步的相对时间：几小时前的老问题和刚发生的问题观感不同
            let ago = app.lastSyncFinishedAt.map { " · \(Self.relativeTime($0))" } ?? ""
            statusButton(text: "部分完成\(ago)", color: Theme.accent,
                         help: warning + "\n主数据已更新，失败部分下轮自动重试")
          } else if let summary = app.lastSummary, summary.status == .stopped,
                    let finishedAt = app.lastSyncFinishedAt {
            statusButton(text: "已停止 \(Self.relativeTime(finishedAt))", color: Theme.textTertiary,
                         help: "上次同步被手动停止，主数据已保留；补全下轮自动继续")
          } else if let lastSync {
            statusButton(text: "已同步 \(Self.relativeTime(lastSync))", color: Theme.textTertiary, help: lastSyncSummary)
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

  /// 状态文字做成可点击按钮：点开同步详情浮层（问题 2 的深化）
  /// TimelineView 让相对时间每分钟自动演进（问题 1 的实时性），挂在前台视图上不产生后台定时器
  private func statusButton(text: String, color: Color, help: String) -> some View {
    SyncStatusButton(text: text, color: color, help: help) {
      SyncDetailPopoverContent(summary: app.lastSummary, finishedAt: app.lastSyncFinishedAt)
    }
  }

  /// 相对时间：随当前时刻演进（TimelineView 每分钟重算）
  static func relativeTime(_ date: Date) -> String {
    let seconds = date.timeIntervalSinceNow.magnitude
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
    if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
    return date.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  }
}

/// 顶栏状态：文字 + 下拉箭头，点击弹同步详情；TimelineView(.periodic) 每分钟驱动相对时间重绘
private struct SyncStatusButton<Popover: View>: View {
  let text: String
  let color: Color
  let help: String
  @ViewBuilder var popover: () -> Popover
  @State private var showDetail = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      Button {
        showDetail.toggle()
      } label: {
        HStack(spacing: 4) {
          Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(color)
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color.opacity(0.6))
        }
      }
      .buttonStyle(.plain)
      .help(help)
      .popover(isPresented: $showDetail, arrowEdge: .bottom) {
        popover()
      }
    }
  }
}

/// 同步详情浮层：时间 + 总量 + 分步明细 + 问题说明。
/// 深色面板与筛选浮层同一套 token（Theme.elevated + hairline 描边）
private struct SyncDetailPopoverContent: View {
  let summary: SyncSummary?
  let finishedAt: Date?

  private var headline: String {
    guard let summary else { return "尚未同步" }
    switch summary.status {
    case .success: return "上次同步：全部成功"
    case .warning: return "上次同步：部分完成"
    case .failed: return "上次同步：失败"
    case .stopped: return "上次同步：手动停止"
    }
  }

  private func outcomeIcon(_ outcome: String) -> (symbol: String, color: Color) {
    switch outcome {
    case "ok": return ("checkmark", Theme.accent)
    case "partial": return ("exclamationmark.triangle", Theme.accent)
    default: return ("xmark", .red.opacity(0.9))
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let summary {
        HStack(alignment: .firstTextBaseline) {
          Text(headline)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          if let finishedAt {
            Text(ContentView.relativeTime(finishedAt))
              .font(.system(size: 10.5).monospacedDigit())
              .foregroundStyle(Theme.textTertiary)
          }
        }
        Text("拉取 \(summary.fetchedCount) 条 · 变化 \(summary.changedCount) 条 · 详情补拉 \(summary.detailCount) 条 · 用时 \(String(format: "%.0f", min(summary.durationSeconds, 599))) 秒")
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(Theme.textSecondary)

        Rectangle().fill(Theme.hairline).frame(height: 1)

        VStack(alignment: .leading, spacing: 6) {
          ForEach(summary.steps) { step in
            let icon = outcomeIcon(step.outcome)
            HStack(spacing: 7) {
              Image(systemName: icon.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(icon.color)
                .frame(width: 12)
              Text(step.label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              if let count = step.count {
                Text("\(count) 条")
                  .font(.system(size: 10.5).monospacedDigit())
                  .foregroundStyle(Theme.textSecondary)
              }
            }
          }
        }

        if let error = summary.error, summary.status != .success {
          Rectangle().fill(Theme.hairline).frame(height: 1)
          Text(error)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if summary.status == .warning {
            Text("主数据已更新；失败部分不影响使用，下轮同步自动重试")
              .font(.system(size: 10))
              .foregroundStyle(Theme.textTertiary)
          } else if summary.status == .stopped {
            Text("已提交的数据批次已保留；未执行的补全步骤（详情/首播日/海报/追剧检查）下轮同步自动继续")
              .font(.system(size: 10))
              .foregroundStyle(Theme.textTertiary)
          }
        }
      } else {
        Text("尚未同步")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.textSecondary)
        Text("点击右上角「同步」拉取热门榜与最近更新")
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.textTertiary)
      }
    }
    .padding(14)
    .frame(width: 300, alignment: .leading)
    .background(Theme.elevated)
  }
}
