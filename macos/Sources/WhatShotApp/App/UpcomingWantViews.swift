import SwiftUI
import WhatShotCore

struct UpcomingWantButton: View {
  let work: UpcomingWork
  @Environment(AppModel.self) private var app
  @State private var saving = false
  @State private var error: String?
  private var wanted: Bool { work.releases.contains { app.wantedReleaseIDs.contains($0.id) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        saving = true
        Task {
          do {
            try await app.setWanted(work, wanted: !wanted)
            error = nil
          } catch { self.error = "保存失败，请重试" }
          saving = false
        }
      } label: {
        Label(wanted ? "已想看" : "想看", systemImage: wanted ? "heart.fill" : "heart")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(wanted ? Theme.accent : Theme.textSecondary)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(Theme.bg, in: Capsule())
          .overlay(Capsule().strokeBorder(wanted ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
      }
      .buttonStyle(.plain).disabled(saving || app.queue == nil)
      .help(wanted ? "取消此作品及已收藏平台的想看" : "收藏当前展示的平台排期，之后可在我的想看中查看")
      .accessibilityLabel((wanted ? "取消想看 " : "想看 ") + work.title)
      if let error { Text(error).font(.system(size: 10)).foregroundStyle(Theme.accent) }
    }
  }
}

struct UpcomingChangesView: View {
  let changes: [UpcomingWantChange]
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("排期变动", systemImage: "arrow.triangle.2.circlepath")
        .font(.system(size: 13, weight: .bold))
      if changes.isEmpty {
        Text("关注后尚未发现排期变动").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
      }
      ForEach(changes) { change in
        VStack(alignment: .leading, spacing: 4) {
          Text(change.before.source.title + " · " + change.reason)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
          Text(change.summary).font(.system(size: 11)).foregroundStyle(Theme.textPrimary)
          Text("本地发现 " + ContentView.relativeTime(change.observedAt))
            .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
      }
      Text("只记录关注后成功刷新发现的变动，保留最近 90 天，每个平台展示最近 10 次。移出片单不代表已上线。")
        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
    }
  }
}
