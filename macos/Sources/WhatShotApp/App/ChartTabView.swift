import SwiftUI
import WhatShotCore

/// 热门榜：三个 scope 切换，名次 + 海报 + 标题 + 集数进度 + 评分 + 资源数
struct ChartTabView: View {
  @Environment(AppModel.self) private var app
  @State private var scope: ButaiChartScope = .recent
  @State private var rows: [(rank: Int, video: VideoRepository.VideoRow)] = []
  @State private var loading = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("榜单", selection: $scope) {
        ForEach(ButaiChartScope.allCases, id: \.self) { item in
          Text(item.label).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .padding(8)

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        ContentUnavailableView("暂无数据", systemImage: "chart.bar", description: Text("同步一次后显示热门榜"))
        Spacer()
      } else {
        List(Array(rows.enumerated()), id: \.element.video.id) { index, row in
          ChartRowView(rank: row.rank, video: row.video)
            .listRowSeparator(.hidden)
            .opacity(index < 10 ? 1.0 : 0.85)
        }
        .listStyle(.plain)
      }
    }
    .task(id: scope) { await reload() }
    .refreshable { await reload() }
  }

  func reload() async {
    loading = true
    defer { loading = false }
    guard let repo = app.repo else { return }
    rows = (try? await repo.latestChart(scope)) ?? []
  }
}

/// 榜单行
struct ChartRowView: View {
  let rank: Int
  let video: VideoRepository.VideoRow

  var body: some View {
    HStack(spacing: 10) {
      Text("\(rank)")
        .font(.title3.bold())
        .foregroundStyle(rank <= 3 ? Color.orange : Color.secondary)
        .frame(width: 32)

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
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 8) {
          if let douban = video.doubanScore, douban != "0", !douban.isEmpty {
            Label(douban, systemImage: "star.fill")
              .foregroundStyle(.yellow)
              .help("豆瓣评分")
          }
          if let imdb = video.imdbScore, imdb != "0", !imdb.isEmpty {
            Text("IMDb \(imdb)")
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        Text("种子 \(video.seedCount) · 网盘 \(video.netdiskCount)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

/// 集数徽章："更新至9集"（蓝）/ "全集"（绿）/ 空（灰"已出资源"）
struct EpisodeBadge: View {
  let status: String
  let total: String

  var body: some View {
    if status.contains("全集") {
      Text("全集")
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.green.opacity(0.15))
        .foregroundStyle(.green)
        .clipShape(Capsule())
    } else if let current = parseCurrent {
      Text(current)
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.blue.opacity(0.15))
        .foregroundStyle(.blue)
        .clipShape(Capsule())
    } else {
      EmptyView()
    }
  }

  var parseCurrent: String? {
    let text = status.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return nil }
    if let range = text.range(of: #"更新至(\d+)集"#, options: .regularExpression) {
      return String(text[range])
    }
    return text
  }
}

/// 海报：NSCache 内存缓存 + 磁盘缓存有上限，内存压力系统自动逐出
struct PosterImageView: View {
  let url: String?
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.gray.opacity(0.15))
      if let image = image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .task(id: url) { await load() }
  }

  func load() async {
    guard let url = url, let remote = URL(string: url), image == nil else { return }
    image = await PosterLoader.shared.load(remote)
  }
}