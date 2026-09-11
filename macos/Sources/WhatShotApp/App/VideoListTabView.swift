import SwiftUI
import WhatShotCore

/// 剧集/电影通用列表：分页懒加载 + "更新至X集"徽章
struct TVTabView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VideoListTabView(kind: .tvSeries)
  }
}

struct MovieTabView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VideoListTabView(kind: .movie)
  }
}

struct VideoListTabView: View {
  let kind: ButaiKind
  @Environment(AppModel.self) private var app
  @State private var rows: [VideoRepository.VideoRow] = []
  @State private var loading = false
  @State private var page = 0
  private let pageSize = 60

  var body: some View {
    List {
      ForEach(rows, id: \.id) { row in
        ListRowView(video: row)
          .listRowSeparator(.hidden)
          .onAppear {
            if row.id == rows.last?.id {
              Task { await loadMore() }
            }
          }
      }
      if loading && !rows.isEmpty {
        HStack {
          Spacer()
          ProgressView().controlSize(.small)
          Spacer()
        }
      }
      if rows.isEmpty && !loading {
        Text("暂无数据，同步一次后显示")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.top, 40)
      }
    }
    .listStyle(.plain)
    .overlay(alignment: .top) {
      if loading && rows.isEmpty {
        ProgressView("加载中…").padding(.top, 40)
      }
    }
    .task(id: kind) {
      page = 0
      rows = []
      await loadMore()
    }
    .refreshable { await reload() }
  }

  func reload() async {
    page = 0
    rows = []
    await loadMore()
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

/// 列表行：与榜单行类似但无名次
struct ListRowView: View {
  let video: VideoRepository.VideoRow

  var body: some View {
    HStack(spacing: 10) {
      PosterImageView(url: video.posterURL)
        .frame(width: 44, height: 60)
      VStack(alignment: .leading, spacing: 3) {
        Text(video.title)
          .font(.headline)
          .lineLimit(1)
        HStack(spacing: 6) {
          EpisodeBadge(status: video.episodeStatus, total: video.episodes)
          if let year = video.years, !year.isEmpty, year != "0" {
            Text(year).font(.caption2).foregroundStyle(.secondary)
          }
          if let area = video.productionArea, !area.isEmpty {
            Text(area).font(.caption2).foregroundStyle(.secondary)
          }
          if let definition = video.definition, !definition.isEmpty, definition != "@" {
            Text(definition)
              .font(.caption2)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }
        Text("种子 \(video.seedCount) · 网盘 \(video.netdiskCount)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 8) {
        if let douban = video.doubanScore, douban != "0", !douban.isEmpty {
          Label(douban, systemImage: "star.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
        }
        if let imdb = video.imdbScore, imdb != "0", !imdb.isEmpty {
          Text("IMDb \(imdb)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }
}