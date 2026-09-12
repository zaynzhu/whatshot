import SwiftUI
import WhatShotCore

/// 热门榜：eyebrow 页头（标题=当前榜单名）+ 榜首 hero（宽窗）+ 画廊网格
struct ChartTabView: View {
  @Environment(AppModel.self) private var app
  @State private var scope: ButaiChartScope = .recent
  @State private var rows: [(rank: Int, video: VideoRepository.VideoRow)] = []
  @State private var loading = false

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

  /// 窗口够宽才给榜首 hero 位，窄窗退化为普通网格
  private let heroBreakpoint: CGFloat = 860

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(eyebrow: "CHART · BUTAI0", title: scope.label,
                 subtitle: "热度来自站内资源数，非客观流行度 · 共 \(rows.count) 部") {
        HStack(spacing: 14) {
          ForEach(ButaiChartScope.allCases, id: \.self) { item in
            TextTab(title: item.label, selected: scope == item) { scope = item }
          }
          if loading {
            ProgressView().controlSize(.small).tint(Theme.accent)
          }
        }
      }
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
          Image(systemName: "flame")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Theme.textTertiary)
          Text("暂无数据")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
          Text("点击右上角「同步」拉取热门榜")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
        }
        Spacer()
      } else {
        GeometryReader { geo in
          let heroShown = geo.size.width >= heroBreakpoint
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              if heroShown, let first = rows.first {
                HeroCard(video: first.video, scope: scope)
                  .padding(.bottom, 30)
              }
              LazyVGrid(columns: columns, spacing: 18) {
                ForEach(heroShown ? Array(rows.dropFirst()) : rows, id: \.video.id) { row in
                  GalleryCard(video: row.video, rank: row.rank)
                }
              }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
          }
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

/// 榜首 hero：大海报 + 档案文字块（eyebrow 名次 / 30pt 粗标题 / serif 拉丁原名 /
/// meta 行 / 简介三行 / 唯一保留的 1px 细进度线）
struct HeroCard: View {
  let video: VideoRepository.VideoRow
  let scope: ButaiChartScope
  @State private var hovering = false

  private var episode: EpisodeStatus? {
    EpisodeStatus.parse(status: video.episodeStatus, total: video.episodes)
  }

  /// 原名仅展示拉丁字母（serif italic 只负责拉丁，避开中文衬线回退）
  private var latinTitle: String? {
    let raw = video.originalTitle ?? video.alias
    guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
          text.range(of: #"^\p{Latin}[0-9\p{Latin}\s\p{P}·'-]*$"#, options: .regularExpression) != nil else {
      return nil
    }
    return text
  }

  /// 档案行：年份 · 地区 · 类型
  private var archiveLine: String? {
    let parts = [video.years, video.productionArea, video.classNames]
      .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 22) {
      PosterImage(url: video.posterURL, hovering: hovering)
        .frame(width: 170)

      VStack(alignment: .leading, spacing: 10) {
        Eyebrow(text: "NO.1 · \(scope.label)")

        Text(video.title.decodingHTMLEntities)
          .font(.system(size: 30, weight: .heavy))
          .tracking(-0.5)
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        if let latinTitle {
          Text(latinTitle.decodingHTMLEntities)
            .font(.system(size: 13.5, design: .serif).italic())
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        }

        // 播出进度是 hero 的第二信息层级：紧跟标题区、15pt 琥珀
        if let episode {
          EpisodeStatusText(episode: episode, size: 15)
        }

        HeroMetaLine(video: video)

        if let archiveLine {
          Text(archiveLine.decodingHTMLEntities)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        }

        if let abstract = video.abstract?.trimmingCharacters(in: .whitespacesAndNewlines)
            .decodingHTMLEntities, !abstract.isEmpty {
          Text(abstract)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .lineSpacing(3.5)
            .lineLimit(4)
        }

        Spacer(minLength: 0)

        // hero 专属的 1px 细进度线：全应用仅此一处
        if let ratio = episode?.ratio {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Rectangle().fill(Theme.hairline)
              Rectangle()
                .fill(episode?.isOngoing == true ? Theme.accent : Theme.textTertiary)
                .frame(width: max(2, geo.size.width * ratio))
            }
          }
          .frame(height: 1.5)
        }
      }
      .frame(maxWidth: 470, alignment: .leading)

      Spacer(minLength: 0)
    }
    .animation(.easeOut(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
  }
}

/// hero meta 行：双评分 + 资源数，等宽数字；集数由 EpisodeStatusText 独立承担
private struct HeroMetaLine: View {
  let video: VideoRepository.VideoRow

  var body: some View {
    var line = Text("")
    var segments: [String] = []
    if let douban = cleanedScoreText(video.doubanScore) {
      segments.append("豆 \(douban)")
    }
    if let imdb = cleanedScoreText(video.imdbScore) {
      segments.append("IM \(imdb)")
    }
    if video.seedCount > 0 {
      segments.append("\(video.seedCount) 资源")
    }
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        line = line + Text("  ·  ").foregroundColor(Theme.textTertiary)
      }
      line = line + Text(segment).foregroundColor(Theme.textSecondary)
    }
    return line
      .font(.system(size: 12.5))
      .monospacedDigit()
  }
}
