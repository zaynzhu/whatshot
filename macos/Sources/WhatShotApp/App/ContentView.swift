import SwiftUI
import WhatShotCore

/// 主窗口：顶部品牌栏 + 自绘标签切换 + 内容区 + 底部同步状态栏
struct ContentView: View {
  @Environment(AppModel.self) private var app
  @State private var tab = 0

  private let tabs: [(icon: String, label: String)] = [
    ("flame.fill", "热门榜"),
    ("tv", "剧集"),
    ("film", "电影"),
    ("gearshape", "设置")
  ]

  var body: some View {
    VStack(spacing: 0) {
      // 品牌栏 + 标签
      HStack(spacing: 16) {
        HStack(spacing: 6) {
          Image(systemName: "flame.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.accent)
          Text("WhatShot")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
        }

        HStack(spacing: 2) {
          ForEach(Array(tabs.enumerated()), id: \.offset) { index, item in
            Button {
              withAnimation(.easeOut(duration: 0.15)) { tab = index }
            } label: {
              Label(item.label, systemImage: item.icon)
                .font(.system(size: 12.5, weight: tab == index ? .semibold : .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                  Capsule().fill(tab == index ? Theme.cardHover : Color.clear)
                )
                .foregroundStyle(tab == index ? Theme.textPrimary : Theme.textSecondary)
            }
            .buttonStyle(.plain)
          }
        }

        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)
      .padding(.bottom, 10)
      .background(Theme.bg)

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

      Divider().overlay(Theme.hairline)
      footerBar
    }
    .background(Theme.bg)
    .preferredColorScheme(.dark)
  }

  /// 底部同步状态栏
  var footerBar: some View {
    HStack(spacing: 10) {
      if app.syncing {
        ProgressView()
          .controlSize(.small)
          .tint(Theme.accent)
        Text("同步中…")
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.textSecondary)
      } else {
        Button {
          Task { await app.syncNow() }
        } label: {
          Label("立即同步", systemImage: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accentSoft))
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
      }

      if let summary = app.lastSummary {
        Text("拉取 \(summary.fetchedCount) 条 · 更新 \(summary.changedCount) 条 · 详情 \(summary.detailCount) 条")
          .font(.system(size: 11))
          .foregroundStyle(Theme.textTertiary)
          .lineLimit(1)
      }
      if let error = app.lastError {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.red)
          .help(error)
        Text("同步出错，悬停查看")
          .font(.system(size: 11))
          .foregroundStyle(.red.opacity(0.85))
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 9)
    .background(Theme.bg)
  }
}