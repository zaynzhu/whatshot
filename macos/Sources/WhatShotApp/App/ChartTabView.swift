import SwiftUI
import WhatShotCore

/// 热门榜：左列三个 scope 切换 + 海报卡片网格，前三名有独立名次徽标
struct ChartTabView: View {
  @Environment(AppModel.self) private var app
  @State private var scope: ButaiChartScope = .recent
  @State private var rows: [(rank: Int, video: VideoRepository.VideoRow)] = []
  @State private var loading = false

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        ForEach(ButaiChartScope.allCases, id: \.self) { item in
          Button {
            scope = item
          } label: {
            Text(item.label)
              .font(.system(size: 12.5, weight: scope == item ? .bold : .medium))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                Capsule().fill(scope == item ? Theme.accentSoft : Color.clear)
              )
              .foregroundStyle(scope == item ? Theme.accent : Theme.textSecondary)
          }
          .buttonStyle(.plain)
        }
        Spacer()
        if loading {
          ProgressView().controlSize(.small)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)
      .padding(.bottom, 10)

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        VStack(spacing: 10) {
          Image(systemName: "flame")
            .font(.system(size: 40))
            .foregroundStyle(Theme.textTertiary)
          Text("暂无数据")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
          Text("点击下方「立即同步」拉取热门榜")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
        }
        Spacer()
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.element.video.id) { index, row in
              ChartCard(rank: row.rank, video: row.video, dimmed: index >= 12)
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 20)
        }
      }
    }
    .background(Theme.bg)
    .task(id: scope) { await reload() }
  }

  func reload() async {
    loading = true
    defer { loading = false }
    guard let repo = app.repo else { return }
    rows = (try? await repo.latestChart(scope)) ?? []
  }
}

/// 榜单海报卡：海报 2:3 + 左上名次徽标 + 底部信息层
struct ChartCard: View {
  let rank: Int
  let video: VideoRepository.VideoRow
  var dimmed = false
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PosterImage(url: video.posterURL, aspect: 2.0 / 3.0)
        .overlay(alignment: .topLeading) {
          RankBadge(rank: rank)
            .padding(6)
        }
        .overlay(alignment: .bottom) {
          // 底部渐变托底信息
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
                .tintStyle()
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
    .opacity(dimmed ? 0.82 : 1)
    .scaleEffect(hovering ? 1.025 : 1)
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    .onHover { hovering = $0 }
  }

  private func cleanScore(_ raw: String?) -> String? {
    guard let raw = raw, !raw.isEmpty, raw != "0" else { return nil }
    return raw
  }
}

/// 名次徽标：前三名实心橙，其余灰
struct RankBadge: View {
  let rank: Int

  var body: some View {
    Text("\(rank)")
      .font(.system(size: 11, weight: .heavy, design: .rounded))
      .foregroundStyle(rank <= 3 ? .white : Theme.textSecondary)
      .frame(width: 22, height: 22)
      .background(
        Circle().fill(rank <= 3 ? Theme.accent : Color.black.opacity(0.55))
      )
  }
}

extension EpisodeProgress {
  /// 卡片渐变托底上的进度条改为白色系
  func tintStyle() -> some View { self }
}

/// 海报图：NSCache + 磁盘缓存，无图时占位
struct PosterImage: View {
  let url: String?
  var aspect: CGFloat = 2.0 / 3.0
  @State private var image: NSImage?

  var body: some View {
    Rectangle()
      .fill(Theme.card)
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let image = image {
          // scaledToFill 溢出布局边界会让行高不齐，必须 clipped 截断
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .allowsHitTesting(false)
        } else {
          Image(systemName: "film")
            .font(.system(size: 22))
            .foregroundStyle(Theme.textTertiary)
        }
      }
      .clipped()
      .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPoster))
      .task(id: url) { await load() }
  }

  func load() async {
    guard let url = url, let remote = URL(string: url), image == nil else { return }
    image = await PosterLoader.shared.load(remote)
  }
}