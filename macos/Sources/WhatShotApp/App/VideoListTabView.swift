import SwiftUI
import WhatShotCore

/// 剧集 / 电影：区块页头 + 画廊网格，底部懒加载
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

  // 单元格顶对齐：集数行有无导致的卡片高度差不影响海报齐平
  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(
        eyebrow: kind == .movie ? "MOVIES · BUTAI0" : "SERIES · BUTAI0",
        title: "最近更新",
        subtitle: "按站内更新时间排序 · \(rows.count) 部"
      )
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(.bottom, 16)

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        VStack(spacing: 10) {
          Image(systemName: kind == .movie ? "film" : "tv")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Theme.textTertiary)
          Text("暂无数据")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
          Text("点击右上角「同步」拉取数据")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
        }
        Spacer()
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 18) {
            ForEach(rows, id: \.id) { row in
              GalleryCard(video: row, showDefinition: true)
                .onAppear {
                  if row.id == rows.last?.id {
                    Task { await loadMore() }
                  }
                }
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 22)

          if loading && !rows.isEmpty {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("加载更多…")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 16)
          }
        }
      }
    }
    .background(Theme.bg)
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
