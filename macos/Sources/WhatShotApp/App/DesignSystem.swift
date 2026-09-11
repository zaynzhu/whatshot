import SwiftUI

/// 设计系统：深色影院主题。单一强调色（暖橙=热度），海报为主视觉。
/// 颜色全部 off-black/off-white，不纯黑不纯白。
enum Theme {
  static let bg = Color(red: 0.082, green: 0.088, blue: 0.106)        // #15171b 页面底
  static let card = Color(red: 0.133, green: 0.141, blue: 0.165)      // #22242a 卡片
  static let cardHover = Color(red: 0.176, green: 0.184, blue: 0.212) // hover 卡片
  static let hairline = Color.white.opacity(0.07)
  static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.95)
  static let textSecondary = Color.white.opacity(0.55)
  static let textTertiary = Color.white.opacity(0.38)
  static let accent = Color(red: 0.976, green: 0.451, blue: 0.086)    // #f97316 暖橙
  static let accentSoft = Color(red: 0.976, green: 0.451, blue: 0.086).opacity(0.16)
  /// 豆瓣绿 / IMDb 黄（平台身份色，仅用于评分徽标）
  static let douban = Color(red: 0.259, green: 0.741, blue: 0.337)
  static let imdb = Color(red: 0.961, green: 0.773, blue: 0.208)
  static let radiusCard: CGFloat = 12
  static let radiusPoster: CGFloat = 10
  static let radiusChip: CGFloat = 6
}

/// 通用小组件
enum Components {
  /// 平台评分徽标：豆 7.8（绿）/ IMDb 7.2（黄）
  static func scoreBadge(source: String, value: String) -> some View {
    HStack(spacing: 3) {
      Text(source)
        .font(.system(size: 9, weight: .bold))
      Text(value)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2.5)
    .background(
      Capsule().fill(source == "豆" ? Theme.douban.opacity(0.16) : Theme.imdb.opacity(0.14))
    )
    .foregroundStyle(source == "豆" ? Theme.douban : Theme.imdb)
  }
}

/// 集数进度：解析 ejs 文本 + 总集数，画出 X/Y 进度条；"全集"画满条
struct EpisodeProgress: View {
  let status: String
  let total: String

  private var current: Int? {
    let text = status.trimmingCharacters(in: .whitespaces)
    if text.contains("全集") { return episodeCount }
    if let range = text.range(of: #"更新至(\d+)集"#, options: .regularExpression) {
      let digits = text[range].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
      return Int(digits)
    }
    return nil
  }

  private var episodeCount: Int? {
    let value = total.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, let count = Int(value), count > 0 else { return nil }
    return count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let current = current {
        HStack(spacing: 0) {
          Text(status.contains("全集") ? "已完结" : status)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(status.contains("全集") ? Theme.douban : Theme.accent)
          if let total = episodeCount, !status.contains("全集") {
            Text(" / 共\(total)集")
              .font(.system(size: 10.5))
              .foregroundStyle(Theme.textTertiary)
          }
          Spacer(minLength: 4)
        }
        // 进度条：无背景轨设计，只画已播部分
        GeometryReader { geo in
          let ratio = status.contains("全集")
            ? 1.0
            : (episodeCount.map { min(1.0, Double(current) / Double($0)) } ?? 0)
          HStack(spacing: 0) {
            Capsule()
              .fill(Theme.accent)
              .frame(width: max(4, geo.size.width * ratio))
            Capsule()
              .fill(Theme.hairline)
              .frame(width: geo.size.width - max(4, geo.size.width * ratio))
          }
        }
        .frame(height: 2.5)
      } else if !status.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(status)
          .font(.system(size: 10.5, weight: .semibold, design: .rounded))
          .foregroundStyle(Theme.textSecondary)
      } else if let total = episodeCount {
        Text("共\(total)集")
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.textTertiary)
      }
    }
  }
}