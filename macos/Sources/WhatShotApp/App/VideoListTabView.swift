import SwiftUI
import WhatShotCore

/// 剧集 / 电影：海报卡片网格，底部懒加载
struct TVTabView: View {
  var body: some View {
    VideoGridTabView(kind: .tvSeries)
  }
}

struct MovieTabView: View {
  var body: some View {
    VideoGridTabView(kind: .movie)
  }
}

struct VideoGridTabView: View {
  let kind: ButaiKind
  @Environment(AppModel.self) private var app
  @State private var rows: [VideoRepository.VideoRow] = []
  @State private var loading = false
  @State private var page = 0
  private let pageSize = 60

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

  var body: some View {
    Group {
      if rows.isEmpty && loading {
        ZStack {
          Theme.bg.ignoresSafeArea()
          ProgressView("加载中…").tint(Theme.accent)
        }
      } else if rows.isEmpty {
        ZStack {
          Theme.bg.ignoresSafeArea()
          VStack(spacing: 10) {
            Image(systemName: kind == .movie ? "film" : "tv")
              .font(.system(size: 40))
              .foregroundStyle(Theme.textTertiary)
            Text("暂无数据")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Theme.textSecondary)
            Text("点击底部「立即同步」拉取数据")
              .font(.system(size: 12))
              .foregroundStyle(Theme.textTertiary)
          }
        }
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(rows, id: \.id) { row in
              VideoCard(video: row)
                .onAppear {
                  if row.id == rows.last?.id {
                    Task { await loadMore() }
                  }
                }
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 16)
          .padding(.bottom, 20)

          if loading && !rows.isEmpty {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("加载更多…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 16)
          }
        }
        .background(Theme.bg)
      }
    }
    .task(id: kind) {
      page = 0
      rows = []
      await loadMore()
    }
  }

  func loadMore() async {
    guard !loading, let repo = app.repo else { return }
    loading = true
    defer { loading = false }
    let next = (try? await repo.listVideos(kind: kind, limit: pageSize, offset: page * pageSize)) ?? []
    page += 1
    rows.append(contentsOf: next)
  }
}

/// 剧集/电影海报卡：海报 + 渐变托底标题/进度 + 评分与画质行
struct VideoCard: View {
  let video: VideoRepository.VideoRow
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PosterImage(url: video.posterURL, aspect: 2.0 / 3.0)
        .overlay(alignment: .topTrailing) {
          if let definition = video.definition,
             !definition.isEmpty, definition != "@" {
            Text(definition.components(separatedBy: ",").first ?? "")
              .font(.system(size: 9, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(Capsule().fill(Color.black.opacity(0.55)))
              .foregroundStyle(Theme.accent)
              .padding(6)
          }
        }
        .overlay(alignment: .bottom) {
          LinearGradient(
            colors: [.clear, .black.opacity(0.62)],
            startPoint: .center, endPoint: .bottom
          )
          .allowsHitTesting(false)
          .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 3) {
              Text(video.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
              EpisodeProgress(status: video.episodeStatus, total: video.episodes)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPoster))

      HStack(spacing: 5) {
        if let douban = cleanScore(video.doubanScore) {
          Components.scoreBadge(source: "豆", value: douban)
        }
        if let imdb = cleanScore(video.imdbScore) {
          Components.scoreBadge(source: "IMDb", value: imdb)
        }
        Spacer(minLength: 0)
        HStack(spacing: 2) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 9))
          Text("\(video.seedCount)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(Theme.textTertiary)
      }
      .padding(.horizontal, 2)
    }
    .scaleEffect(hovering ? 1.025 : 1)
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    .onHover { hovering = $0 }
  }

  private func cleanScore(_ raw: String?) -> String? {
    guard let raw = raw, !raw.isEmpty, raw != "0" else { return nil }
    return raw
  }
}