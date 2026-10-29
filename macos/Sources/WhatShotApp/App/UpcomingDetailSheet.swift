import SwiftUI
import WhatShotCore

struct UpcomingDetailSheet: View {
  let row: UpcomingWork
  let connection: WorkConnection
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var localVideo: VideoRepository.VideoRow?
  @State private var changesPage = 0
  @State private var remainingUnread = false
  @State private var changes: [UpcomingWantChange] = []
  @State private var inactiveIDs = Set<String>()
  @State private var watched = false
  @State private var savingWatch = false
  @State private var error: String?

  private var localCharts: [LocalChartSignal] { connection.videoID.flatMap { app.localChartSignals[$0] } ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 18) {
        SignalPoster(url: row.posterURL, signals: app.signals(for: connection), localCharts: localCharts).frame(width: 112)
        VStack(alignment: .leading, spacing: 8) {
          Text(connection.chineseTitle ?? row.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
          if connection.chineseTitle != nil && connection.chineseTitle != row.title {
            Text(row.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
          }
          Text(row.kind == "movie" ? "电影" : "剧集").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
          UpcomingWantButton(work: row)
          if let basis = connection.basis {
            Text("作品关联 · " + basis).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
          }
          if let id = connection.videoID {
            OutlineButton(title: "查看片库详情", icon: "rectangle.stack") {
              Task { localVideo = try? await app.repo?.video(id: id) }
            }
            Button {
              savingWatch = true
              Task {
                do {
                  guard let repo = app.repo else { savingWatch = false; return }
                  try await repo.addToWatchlist(videoID: id, at: Date())
                  watched = true
                  error = nil
                } catch { self.error = "加入追剧失败，请重试" }
                savingWatch = false
              }
            } label: {
              Label(watched ? "已在追剧" : "加入追剧", systemImage: watched ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }.buttonStyle(.plain).disabled(watched || savingWatch)
          }
        }
        Spacer(minLength: 0)
        Button { dismiss() } label: { Image(systemName: "xmark").padding(7) }
          .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.accent) }
          ForEach(row.releases.filter { inactiveIDs.contains($0.id) && app.settings.enabledUpcomingSources.contains($0.source) }) { release in
            Text(release.source.title + "已移出片单，下方保留上次排期，是否上线未确认。")
              .font(.system(size: 11)).foregroundStyle(Theme.accent)
          }
          UpcomingScheduleList(releases: row.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) })
          if row.releases.contains(where: { app.wantedReleaseIDs.contains($0.id) }) {
            Divider().overlay(Theme.hairline)
            UpcomingChangesView(changes: changes)
            if remainingUnread {
              OutlineButton(title: "还有未读变动 · 继续查看", icon: "chevron.down") { changesPage += 1 }
            }
          }
          if !localCharts.isEmpty {
            Divider().overlay(Theme.hairline)
            LocalChartsPanel(signals: localCharts)
          }
          let signals = app.signals(for: connection)
          if !signals.isEmpty {
            Divider().overlay(Theme.hairline)
            ExternalSignalsPanel(signals: signals) { signal in dismiss(); app.openExternal(signal) }
          }
        }
      }
      .frame(maxHeight: 320)
    }
    .padding(24).frame(width: 540).background(Theme.elevated)
    .sheet(item: $localVideo, onDismiss: {
      Task {
        do {
          if let id = connection.videoID { watched = try await app.repo?.isWatched(videoID: id) ?? false }
        } catch { self.error = "追剧状态读取失败，请重新打开详情" }
      }
    }) { video in DetailSheet(video: video, repo: app.repo) }
    .onChange(of: app.externalFocus) { _, _ in dismiss() }
    // 来源与排期更新时重读本批变动；只确认当前详情实际载入的事件。
    .task(id: "\(app.wishlistRevision)|\(app.upcomingRevision)|\(app.settings.enabledUpcomingSources)|\(changesPage)") {
      guard let queue = app.queue else { return }
      do {
        try await app.reloadWishlist()
        let store = UpcomingWishlistStore(queue: queue)
        let ids = row.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) }.map(\.id)
        changes = try await store.changes(for: ids)
        inactiveIDs = try await store.inactiveIDs(for: ids)
        if let id = connection.videoID { watched = try await app.repo?.isWatched(videoID: id) ?? false }
        try Task.checkCancellation()
        if localVideo == nil { try await store.markRead(changeIDs: changes.map(\.id)) }
        remainingUnread = try await store.hasUnread(for: ids)
        error = nil
      } catch is CancellationError {
      } catch { self.error = "想看记录读取失败，请重新打开详情" }
    }
  }
}
