import SwiftUI
import WhatShotCore

/// 设计系统「深夜画廊·档案版」：单色琥珀纪律（每次出现都携带信息），
/// 零阴影零渐变托底，层级靠字重、等宽数字与留白。
/// 参考 re0.me（单黄/eyebrow/极端字重对比）与 whatsnew（cinemaGold/serif 拉丁/等宽数字）。
enum Theme {
  static let bg = Color(red: 0.063, green: 0.063, blue: 0.075)       // #101013 页底
  static let elevated = Color(red: 0.098, green: 0.102, blue: 0.118) // #191A1E 浮层/卡片
  static let hairline = Color.white.opacity(0.08)
  static let hairlineHover = Color.white.opacity(0.20)
  static let textPrimary = Color(red: 0.941, green: 0.941, blue: 0.949) // #F0F0F2
  static let textSecondary = Color.white.opacity(0.55)
  static let textTertiary = Color.white.opacity(0.33)
  /// 琥珀金：whatsnew cinemaGold 的提亮版，仅用于选中下划线、更新中、前三名、主按钮
  static let accent = Color(red: 0.851, green: 0.643, blue: 0.255)   // #D9A441
  static let onAccent = Color(red: 0.086, green: 0.075, blue: 0.043) // 金底上的近黑暖字
  static let radiusPoster: CGFloat = 8
  static let radiusControl: CGFloat = 6
  static let radiusCard: CGFloat = 10
}

/// 空白、纯 0、0.0 都视为无评分，避免渲染出裸标签
func cleanedScoreText(_ raw: String?) -> String? {
  guard let value = raw?.trimmingCharacters(in: .whitespaces),
        !value.isEmpty,
        Double(value).map({ $0 > 0 }) == true else { return nil }
  return value
}

// MARK: - 字级与组件

extension String {
  /// 解码常见 HTML 实体（数据源片名/简介带 &#39; &amp; 这类残留）：数字实体 + 具名实体
  var decodingHTMLEntities: String {
    guard contains("&") else { return self }
    var result = self
    // 数字实体：&#39; / &#x27;
    if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) {
      let full = NSRange(result.startIndex..<result.endIndex, in: result)
      for match in regex.matches(in: result, range: full).reversed() {
        guard let body = Range(match.range(at: 1), in: result),
              let whole = Range(match.range, in: result) else { continue }
        let raw = result[body]
        let scalar = (raw.hasPrefix("x") || raw.hasPrefix("X"))
          ? UInt32(raw.dropFirst(), radix: 16)
          : UInt32(raw)
        if let scalar, let unit = Unicode.Scalar(scalar) {
          result.replaceSubrange(whole, with: String(Character(unit)))
        }
      }
    }
    // 具名实体：&amp; 必须最后解，避免双重解码嵌套
    for (name, rep) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
      result = result.replacingOccurrences(of: name, with: rep)
    }
    return result
  }
}

/// 琥珀宽字距 eyebrow 小标（拉丁全大写），区块头的"杂志感"来源
struct Eyebrow: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .semibold).monospacedDigit())
      .tracking(2.2)
      .foregroundStyle(Theme.accent)
  }
}

/// 文字式 tab：选中项下方 2px 琥珀短线（re0.me 同款模式）
struct TextTab: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Text(title)
          .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        Rectangle()
          .fill(selected ? Theme.accent : Color.clear)
          .frame(width: 16, height: 2)
      }
    }
    .buttonStyle(.plain)
  }
}

/// 描边按钮（次操作）：透明底 + hairline 描边
struct OutlineButton: View {
  let title: String
  var icon: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 10.5, weight: .semibold))
        }
        Text(title)
          .font(.system(size: 12, weight: .medium))
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 5.5)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.radiusControl)
          .stroke(Theme.hairline, lineWidth: 1)
      )
      .foregroundStyle(Theme.textPrimary)
    }
    .buttonStyle(.plain)
  }
}

/// 主按钮（唯一实底）：金底近黑字
struct AccentButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .foregroundStyle(Theme.onAccent)
    }
    .buttonStyle(.plain)
  }
}

/// 区块页头：eyebrow + 粗标题 + 副标，尾部可放切换控件
struct PageHeader<Trailing: View>: View {
  let eyebrow: String
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(text: eyebrow)
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.system(size: 26, weight: .heavy))
          .tracking(-0.5)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        trailing()
      }
      if let subtitle {
        Text(subtitle)
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.textTertiary)
      }
    }
  }
}

extension PageHeader where Trailing == EmptyView {
  init(eyebrow: String, title: String, subtitle: String? = nil) {
    self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
  }
}

/// 名次小片：两位数编号，前三名琥珀（"前三"是唯一用色的名次信号）
struct RankPlate: View {
  let rank: Int

  var body: some View {
    Text(String(format: "%02d", rank))
      .font(.system(size: 11, weight: .semibold, design: .monospaced))
      .foregroundStyle(rank <= 3 ? Theme.accent : Theme.textSecondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2.5)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(rank <= 3 ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1)
      )
  }
}

// MARK: - 集数进度

/// ejs 解析结果；卡片只做文本，hero 用 ratio 画 1px 细进度线
struct EpisodeStatus: Equatable {
  let text: String
  let isOngoing: Bool
  let ratio: Double?

  /// 「更新至9集」→ 更至 9/24（进行中）；「全集」→ 全集 12 集；空取总集数
  static func parse(status raw: String, total rawTotal: String) -> EpisodeStatus? {
    let status = raw.trimmingCharacters(in: .whitespaces)
    let total = Int(rawTotal.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }

    if status.contains("全集") {
      let text = total.map { "全集 \($0) 集" } ?? "全集"
      return EpisodeStatus(text: text, isOngoing: false, ratio: 1)
    }
    if let range = status.range(of: #"更新至(\d+)集"#, options: .regularExpression),
       let current = Int(status[range].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)) {
      if let total {
        return EpisodeStatus(text: "更至 \(current)/\(total)", isOngoing: true,
                             ratio: min(1, Double(current) / Double(total)))
      }
      return EpisodeStatus(text: "更至 \(current) 集", isOngoing: true, ratio: nil)
    }
    if !status.isEmpty { return EpisodeStatus(text: status, isOngoing: false, ratio: nil) }
    if let total { return EpisodeStatus(text: "共 \(total) 集", isOngoing: false, ratio: nil) }
    return nil
  }
}

/// 集数独立行：更新中=琥珀（在播信号），其余=灰；无集数状态时不渲染
struct EpisodeStatusText: View {
  let episode: EpisodeStatus
  var size: CGFloat = 12

  var body: some View {
    Text(episode.text)
      .font(.system(size: size, weight: .semibold).monospacedDigit())
      .foregroundStyle(episode.isOngoing ? Theme.accent : Theme.textSecondary)
  }
}

// MARK: - 海报与卡片

/// 海报图：NSCache + 磁盘缓存；细描边，hover 时描边亮起
struct PosterImage: View {
  let url: String?
  var aspect: CGFloat = 2.0 / 3.0
  var hovering = false
  @State private var image: NSImage?

  var body: some View {
    Rectangle()
      .fill(Theme.elevated)
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .allowsHitTesting(false)
        } else {
          Image(systemName: "film")
            .font(.system(size: 16))
            .foregroundStyle(Theme.textTertiary)
        }
      }
      .clipped()
      .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPoster))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.radiusPoster)
          .stroke(hovering ? Theme.hairlineHover : Theme.hairline, lineWidth: 1)
      )
      .task(id: url) { await load() }
  }

  func load() async {
    guard let url, let remote = URL(string: url), image == nil else { return }
    image = await PosterLoader.shared.load(remote)
  }
}

/// 海报下方 meta 行：豆 7.8 · IM 7.4 · 214（· 4K）——纯评分与资源数，集数由 EpisodeStatusText 独立承担
/// 单文本截断
struct VideoMetaLine: View {
  let video: VideoRepository.VideoRow
  var showDefinition = false

  private var segments: [String] {
    var list: [String] = []
    if let douban = cleanScore(video.doubanScore) { list.append("豆 \(douban)") }
    if let imdb = cleanScore(video.imdbScore) { list.append("IM \(imdb)") }
    if video.seedCount > 0 { list.append("\(video.seedCount)") }
    if showDefinition, let definition = definitionText { list.append(definition) }
    return list
  }

  private var definitionText: String? {
    guard let raw = video.definition, !raw.isEmpty, raw != "@" else { return nil }
    return raw.components(separatedBy: ",").first
  }

  /// 空白、纯 0、0.0 都视为无评分，避免渲染出裸标签
  private func cleanScore(_ raw: String?) -> String? {
    cleanedScoreText(raw)
  }

  var body: some View {
    var line = Text("")
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        line = line + Text("  ·  ").foregroundColor(Theme.textTertiary)
      }
      line = line + Text(segment).foregroundColor(Theme.textSecondary)
    }
    return line
      .font(.system(size: 10.5).monospacedDigit())
      .lineLimit(1)
  }
}

/// 画廊卡：名次小片（可选）+ 海报 + 片名 + meta 行；hover 仅描边亮起
struct GalleryCard: View {
  let video: VideoRepository.VideoRow
  var rank: Int? = nil
  var showDefinition = false
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let rank {
        RankPlate(rank: rank)
          .padding(.bottom, 1)
      }
      PosterImage(url: video.posterURL, hovering: hovering)
      Text(video.title.decodingHTMLEntities)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
      // 集数是仅次于片名的信息层级：独立一行；电影/无集数时省略
      if let episode = EpisodeStatus.parse(status: video.episodeStatus, total: video.episodes) {
        EpisodeStatusText(episode: episode)
      }
      VideoMetaLine(video: video, showDefinition: showDefinition)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
  }
}
