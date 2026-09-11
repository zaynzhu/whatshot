import SwiftUI
import WhatShotCore

/// 主面板：四个标签页
struct ContentView: View {
  @Environment(AppModel.self) private var app
  @State private var tab = 0

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $tab) {
        ChartTabView()
          .tabItem { Label("热门榜", systemImage: "chart.bar.fill") }
          .tag(0)
        TVTabView()
          .tabItem { Label("剧集", systemImage: "tv") }
          .tag(1)
        MovieTabView()
          .tabItem { Label("电影", systemImage: "film") }
          .tag(2)
        SettingsTabView()
          .tabItem { Label("设置", systemImage: "gearshape") }
          .tag(3)
      }
      footerBar
    }
    .task { await app.bootstrapIfNeeded() }
  }

  var footerBar: some View {
    HStack(spacing: 12) {
      if app.syncing {
        ProgressView()
          .controlSize(.small)
        Text("同步中…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Button {
          Task { await app.syncNow() }
        } label: {
          Label("立即同步", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
      }
      if let summary = app.lastSummary {
        Text("上次拉取 \(summary.fetchedCount) 条，更新 \(summary.changedCount) 条，详情 \(summary.detailCount) 条")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let error = app.lastError {
        Text(error)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(1)
          .help(error)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }
}