import SwiftUI
import WhatShotCore

struct UpcomingDetailSheet: View {
  let row: UpcomingWork
  let connection: WorkConnection
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var localVideo: VideoRepository.VideoRow?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 18) {
        SignalPoster(url: row.posterURL, signals: app.signals(for: connection)).frame(width: 112)
        VStack(alignment: .leading, spacing: 8) {
          Text(connection.chineseTitle ?? row.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
          if connection.chineseTitle != nil && connection.chineseTitle != row.title {
            Text(row.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
          }
          Text(row.kind == "movie" ? "电影" : "剧集").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
          if let basis = connection.basis {
            Text("作品关联 · " + basis).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
          }
          if let id = connection.videoID {
            OutlineButton(title: "查看片库详情", icon: "rectangle.stack") {
              Task { localVideo = try? await app.repo?.video(id: id) }
            }
          }
        }
        Spacer(minLength: 0)
        Button { dismiss() } label: { Image(systemName: "xmark").padding(7) }
          .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          UpcomingScheduleList(releases: row.releases.filter { app.settings.enabledUpcomingSources.contains($0.source) })
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
    .sheet(item: $localVideo) { video in DetailSheet(video: video, repo: app.repo) }
    .onChange(of: app.externalFocus) { _, _ in dismiss() }
  }
}
