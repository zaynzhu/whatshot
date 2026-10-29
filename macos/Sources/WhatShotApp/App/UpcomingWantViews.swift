import SwiftUI
import WhatShotCore

struct UpcomingWantButton: View {
  let work: UpcomingWork
  @Environment(AppModel.self) private var app
  @State private var saving = false
  @State private var error: String?
  @State private var managedWork: UpcomingWork?
  private var visible: [UpcomingRelease] {
    work.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) }
  }
  private var saved: [UpcomingRelease] { visible.filter { app.wantedReleaseIDs.contains($0.id) } }
  private var label: String { saved.isEmpty ? "想看" : "已关注 \(saved.count)/\(visible.count) 个平台" }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        error = nil
        if saved.isEmpty {
          save(visible, wanted: true)
        } else {
          managedWork = UpcomingWork(id: work.id, releaseDate: work.releaseDate, releases: visible)
        }
      } label: {
        Label(label, systemImage: saved.isEmpty ? "heart" : "heart.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(saved.isEmpty ? Theme.textSecondary : Theme.accent)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(Theme.bg, in: Capsule())
          .overlay(Capsule().strokeBorder(saved.isEmpty ? Theme.hairline : Theme.accent.opacity(0.5), lineWidth: 1))
      }
      .buttonStyle(.plain).disabled(saving || app.queue == nil || visible.isEmpty)
      .help(saved.isEmpty ? "关注当前卡片的平台排期" : "查看已关注平台、补充关注或取消")
      .accessibilityLabel(label + " " + work.title)
      .popover(item: $managedWork) { selection in
        let available = selection.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) }
        let followed = available.filter { app.wantedReleaseIDs.contains($0.id) }
        let missing = available.filter { !app.wantedReleaseIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
          Text("管理想看").font(.system(size: 14, weight: .bold))
          Text(work.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
          ForEach(available) { release in
            HStack {
              Text(release.source.title)
              Spacer()
              Text(app.wantedReleaseIDs.contains(release.id) ? "已关注" : "未关注")
                .foregroundStyle(app.wantedReleaseIDs.contains(release.id) ? Theme.accent : Theme.textTertiary)
            }.font(.system(size: 12))
          }
          if !missing.isEmpty {
            Button("补充关注其余 \(missing.count) 个平台") { save(missing, wanted: true) }
              .disabled(saving)
            Text("新增平台从现在开始记录排期变动。")
              .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
          }
          if !followed.isEmpty {
            Divider()
            Text("取消范围：" + followed.map { $0.source.title }.joined(separator: "、"))
              .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text("将清除上述平台的想看及排期变动记录，其他平台不受影响。")
              .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Button("确认取消上述 \(followed.count) 个平台", role: .destructive) {
              save(followed, wanted: false)
            }.disabled(saving)
          }
          if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.accent) }
        }.padding(16).frame(width: 300).background(Theme.elevated)
      }
      if let error, managedWork == nil { Text(error).font(.system(size: 10)).foregroundStyle(Theme.accent) }
    }
  }

  private func save(_ releases: [UpcomingRelease], wanted: Bool) {
    let target = UpcomingWork(id: work.id, releaseDate: work.releaseDate, releases: releases)
    saving = true
    Task {
      do {
        try await app.setWanted(target, wanted: wanted)
        error = nil
        managedWork = nil
      } catch { self.error = "保存失败，请重试" }
      saving = false
    }
  }
}

struct UpcomingChangesView: View {
  let changes: [UpcomingWantChange]
  private func changeColor(_ change: UpcomingWantChange) -> Color {
    if change.label.contains("提前") || change.label.contains("公布") { return .mint }
    if change.label.contains("延期") || change.label.contains("推迟") { return .orange }
    if change.label.contains("撤回") || change.label == "移出片单" { return .pink }
    return Theme.accent
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("排期变动", systemImage: "arrow.triangle.2.circlepath")
        .font(.system(size: 13, weight: .bold))
      if changes.isEmpty {
        Text("关注后尚未发现排期变动").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
      }
      ForEach(changes) { change in
        VStack(alignment: .leading, spacing: 4) {
          Text((change.isRead ? "" : "未读 · ") + change.before.source.title + " · " + change.label)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(changeColor(change))
          Text(change.summary).font(.system(size: 11)).foregroundStyle(Theme.textPrimary)
          Text("本地发现 " + ContentView.relativeTime(change.observedAt))
            .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
      }
      Text("只记录关注后成功刷新发现的变动，保留最近 90 天，每个平台优先展示 10 条未读，查看详情后记为已读。移出片单不代表已上线。")
        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
    }
  }
}
