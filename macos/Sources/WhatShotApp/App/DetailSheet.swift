import SwiftUI
import WhatShotCore

/// 详情浮层：点画廊卡片弹出。左侧大海报，右侧元信息（简介/主演/导演/原名等），
/// 底部集数推进时间线（本地 observations，90 天窗口）。
/// 数据全部来自本地库；外链只跳豆瓣/IMDb 条目页，不携带任何本机信息
struct DetailSheet: View {
  let video: VideoRepository.VideoRow
  let repo: VideoRepository?
  @Environment(\.dismiss) private var dismiss
  @State private var observations: [VideoRepository.ObservationRow] = []

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      // 左：大海报（与画廊同源组件，固定宽）
      PosterImage(url: video.posterURL)
        .frame(width: 180)
        .fixedSize()

      // 右：元信息
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Text(video.title.decodingHTMLEntities)
            .font(.system(size: 19, weight: .heavy))
            .foregroundStyle(Theme.textPrimary)
          metaLine
          if let premiere = video.premiereDate {
            Text("首播 \(premiere)")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(Theme.accent)
          }
        }

        if let overview = video.abstract?.decodingHTMLEntities, !overview.isEmpty {
          Text(overview)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(3)
        }

        if !credits.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(credits, id: \.0) { label, value in
              HStack(alignment: .top, spacing: 8) {
                Text(label)
                  .font(.system(size: 10.5, weight: .semibold))
                  .foregroundStyle(Theme.textTertiary)
                  .frame(width: 40, alignment: .trailing)
                Text(value)
                  .font(.system(size: 11.5))
                  .foregroundStyle(Theme.textPrimary)
                  .lineLimit(2)
              }
            }
          }
        }

        externalLinks

        if !observations.isEmpty {
          Rectangle().fill(Theme.hairline).frame(height: 1)
          VStack(alignment: .leading, spacing: 4) {
            Text("集数推进 · 本地观察")
              .font(.system(size: 10, weight: .semibold).monospacedDigit())
              .tracking(1.6)
              .foregroundStyle(Theme.textTertiary)
            // 最近 6 条变化（同值去重后），最新在上
            ForEach(Array(episodeChanges.prefix(6).enumerated()), id: \.offset) { _, change in
              HStack(spacing: 8) {
                Text(change.day)
                  .font(.system(size: 10.5).monospacedDigit())
                  .foregroundStyle(Theme.textTertiary)
                Text(change.text)
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(Theme.textPrimary)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // 右上角关闭：sheet 模态在部分窗口层级下 Esc 会失效，显式按钮保证可关
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Theme.textTertiary)
          .frame(width: 24, height: 24)
          .background(Theme.bg, in: Circle())
          .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(20)
    .frame(width: 620)
    .background(Theme.elevated)
    .task { await loadObservations() }
  }

  // MARK: - 元信息行

  private var metaLine: some View {
    var parts: [String] = []
    if let years = video.years, !years.isEmpty { parts.append(years) }
    if let area = video.productionArea, !area.isEmpty { parts.append(area) }
    if let classes = video.classNames, !classes.isEmpty { parts.append(classes) }
    if let def = video.definition, !def.isEmpty, def != "@" {
      parts.append(def.components(separatedBy: ",").first ?? def)
    }
    let text = parts.joined(separator: " / ")
    return Group {
      if !text.isEmpty {
        Text(text)
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.textSecondary)
      }
    }
  }

  /// 主演/导演/原名：空值不渲染行
  private var credits: [(String, String)] {
    var rows: [(String, String)] = []
    if let performer = video.performer?.decodingHTMLEntities, !performer.isEmpty {
      rows.append(("主演", performer))
    }
    if let director = video.director?.decodingHTMLEntities, !director.isEmpty {
      rows.append(("导演", director))
    }
    if let otitle = video.originalTitle?.decodingHTMLEntities, !otitle.isEmpty, otitle != video.title {
      rows.append(("原名", otitle))
    }
    return rows
  }

  /// 豆瓣 / IMDb 外链行：有 ID 才显示对应链接
  private var externalLinks: some View {
    HStack(spacing: 14) {
      if let doubanId = video.doubanId {
        Link(destination: URL(string: "https://movie.douban.com/subject/\(doubanId)/")!) {
          Label("豆瓣", systemImage: "arrow.up.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
      }
      if let imdb = video.imdbNumber, !imdb.isEmpty {
        Link(destination: URL(string: "https://www.imdb.com/title/\(imdb)/")!) {
          Label("IMDb \(imdb)", systemImage: "arrow.up.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
      }
      if let doubanScore = cleanedScoreText(video.doubanScore) {
        Text("豆瓣 \(doubanScore)")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(Theme.textSecondary)
      }
      if let imdbScore = cleanedScoreText(video.imdbScore) {
        Text("IMDb \(imdbScore)")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(Theme.textSecondary)
      }
    }
  }

  // MARK: - 集数推进时间线

  struct EpisodeChange: Equatable {
    let day: String
    let text: String
  }

  /// observations → 集数变化序列：ejs 同值去重（反复同步不产生重复行）、倒序（最新在上）
  private var episodeChanges: [EpisodeChange] {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd"
    var changes: [EpisodeChange] = []
    var lastEjs: String?
    for obs in observations { // observations 已按 observed_at 倒序
      guard let ejs = obs.ejs, !ejs.isEmpty else { continue }
      if ejs == lastEjs { continue }
      changes.append(EpisodeChange(day: formatter.string(from: obs.observedAt), text: ejs))
      lastEjs = ejs
    }
    return changes
  }

  private func loadObservations() async {
    guard let repo else { return }
    observations = (try? await repo.observations(videoID: video.id, limit: 200)) ?? []
  }
}