import SwiftUI
import WhatShotCore

/// 我的追剧（2026-09-20 定案七）：关注列表 + 自上次查看的更新汇总。
/// 离开热门榜与最近更新页的作品由同步引擎每轮有限预算检查（watchlistBudgetPerRun）
struct WatchlistTabView: View {
  @Environment(AppModel.self) private var app
  @State private var rows: [VideoRepository.WatchlistRow] = []
  /// 本次进入时读到的更新明细：展示后立即推进水位（已读），明细保留到下次进入
  @State private var updates: [VideoRepository.WatchlistUpdate] = []
  @State private var loading = false
  @State private var detailTarget: VideoRepository.VideoRow?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(
        eyebrow: "WATCHLIST · LOCAL",
        title: "我的追剧",
        subtitle: "共 \(rows.count) 部 · 离开榜单后每轮同步仍有限检查"
      )
      .padding(.horizontal, 20)
      .padding(.top, 18)

      if !updates.isEmpty {
        updatesSection
          .padding(.horizontal, 20)
          .padding(.top, 14)
      }

      headerDivider
        .padding(.top, 14)

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        emptyState
        Spacer()
      } else {
        listSection
      }
    }
    .background(Theme.bg)
    .task { await reload(markViewed: true) }
    // 同步完成后刷新（新观察可能带来新变化），但不重复推进水位
    .onChange(of: app.lastSummary) { _, _ in
      Task { await reload(markViewed: false) }
    }
    .sheet(item: $detailTarget) { target in
      DetailSheet(video: target, repo: app.repo)
    }
  }

  // MARK: - 区块

  /// 更新汇总区块：自上次查看以来的集数推进。时间是本地发现时间，不冒充播出日
  private var updatesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("自上次查看 · \(updates.count) 部有更新", systemImage: "sparkles")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Theme.accent)
      ForEach(Array(updates.enumerated()), id: \.element.video.id) { _, update in
        HStack(spacing: 8) {
          Text(update.video.title.decodingHTMLEntities)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          Text(updateText(update))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.accent)
          Spacer(minLength: 12)
          Text("\(ContentView.relativeTime(update.observedAt))发现")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { detailTarget = update.video }
      }
    }
    .padding(14)
    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radiusCard)
        .stroke(Theme.hairline, lineWidth: 1)
    )
  }

  /// "更新至9集 → 更新至12集" / "更新至9集 → 已完结"（全集）；from 为空不渲染（有基线才叫变化）
  private func updateText(_ update: VideoRepository.WatchlistUpdate) -> String {
    let to = update.toEjs.map { $0.contains("全集") ? "已完结" : $0 } ?? "?"
    if let from = update.fromEjs {
      return "\(from) → \(to)"
    }
    return to
  }

  private var headerDivider: some View {
    Rectangle()
      .fill(Theme.hairline)
      .frame(height: 1)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "bookmark")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(Theme.textTertiary)
      Text("还没有追剧")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
      Text("在作品详情浮层里点「追剧」，更新会汇总到这里")
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
    }
    .frame(maxWidth: .infinity)
  }

  private var listSection: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.video.id) { index, row in
          if index > 0 {
            Rectangle().fill(Theme.hairline).frame(height: 1)
          }
          watchRow(row)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .padding(.bottom, 22)
    }
  }

  private func watchRow(_ row: VideoRepository.WatchlistRow) -> some View {
    let episode = EpisodeStatus.parse(status: row.video.episodeStatus, total: row.video.episodes)
    return HStack(spacing: 14) {
      PosterImage(url: row.video.posterURL)
        .frame(width: 44)
        .fixedSize()

      VStack(alignment: .leading, spacing: 4) {
        Text(row.video.title.decodingHTMLEntities)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
        HStack(spacing: 8) {
          if let episode {
            EpisodeStatusText(episode: episode)
          }
          // 完结标注只认站点 ejs 的"全集"形态；未知状态（仅有总集数）不冒充完结
          if row.video.episodeStatus.contains("全集") {
            Text("已完结")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Theme.textTertiary)
          }
          Text("检查于 \(ContentView.relativeTime(row.video.lastSyncedAt))")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
        }
      }

      Spacer(minLength: 12)

      Button {
        Task {
          try? await app.repo?.removeFromWatchlist(videoID: row.video.id)
          await reload(markViewed: false)
        }
      } label: {
        Image(systemName: "xmark.circle")
          .font(.system(size: 13))
          .foregroundStyle(Theme.textTertiary)
      }
      .buttonStyle(.plain)
      .help("取消关注")
      .padding(.trailing, 4)
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .onTapGesture { detailTarget = row.video }
  }

  // MARK: - 数据

  /// markViewed=true 仅进入页面时：先读明细展示，再推进水位（下次同步的变化从现在算起）
  private func reload(markViewed: Bool) async {
    guard let repo = app.repo else { return }
    loading = rows.isEmpty
    defer { loading = false }
    if markViewed {
      updates = (try? await repo.watchlistUpdates(since: watermarkBeforeViewing())) ?? []
      app.markWatchlistViewed()
    }
    rows = (try? await repo.watchlistRows()) ?? []
    await app.refreshWatchlistUnread()
  }

  /// 推进水位前先取旧水位：保证读到的是"上次查看以来"的变化而非本次进入瞬间的
  private func watermarkBeforeViewing() -> Date {
    let ts = UserDefaults.standard.double(forKey: "watchlist.lastViewed")
    return ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast
  }
}
