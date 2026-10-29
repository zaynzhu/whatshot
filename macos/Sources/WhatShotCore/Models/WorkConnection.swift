import Foundation

/// 展示身份与排期身份分离；中文名不参与待播分组。
public struct WorkConnection: Sendable, Equatable {
  public var videoID: Int?
  public var mediaID: String?
  public var chineseTitle: String?
  public var basis: String?
  // 仅供本地归并核验，不把中文译名当身份。
  var verifiedIDs: [String: String] = [:]
  public static let empty = WorkConnection()

  public init(videoID: Int? = nil, mediaID: String? = nil, chineseTitle: String? = nil, basis: String? = nil) {
    self.videoID = videoID
    self.mediaID = mediaID
    self.chineseTitle = chineseTitle
    self.basis = basis
  }

  public static func combined(_ values: [WorkConnection]) -> WorkConnection {
    let videos = Set(values.compactMap(\.videoID))
    let media = Set(values.compactMap(\.mediaID))
    guard videos.count <= 1, media.count <= 1 else { return .empty }
    return WorkConnection(videoID: videos.first, mediaID: media.first,
      chineseTitle: values.compactMap(\.chineseTitle).first, basis: values.compactMap(\.basis).first)
  }

  public static func isChinese(_ value: String) -> Bool {
    value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
  }
}

/// 当前强调是界面新鲜度判断，不宣称已经下榜或合成跨来源热度。
public enum ExternalSignalPresentation {
  public static func isHeat(_ source: String) -> Bool {
    ["bilibili_rank", "netflix_top10", "tmdb_trending", "tmdb_tv_trending", "trakt_trending", "youku_hot"].contains(source)
  }

  public static func isFresh(_ row: ExternalHeatStore.DisplayRow, now: Date = .now) -> Bool {
    guard row.isCurrent, let captured = row.capturedAt else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: captured) ?? ISO8601DateFormatter().date(from: captured)
    guard let date else { return false }
    return [date, row.fetchedAt].allSatisfy { now.timeIntervalSince($0) >= -300 && now.timeIntervalSince($0) <= 48 * 3600 }
  }

  public static func hasHeat(_ rows: [ExternalHeatStore.DisplayRow], now: Date = .now) -> Bool {
    rows.contains { isHeat($0.source) && isFresh($0, now: now) }
  }

  public static func rise(_ row: ExternalHeatStore.DisplayRow, now: Date = .now) -> Int? {
    guard isHeat(row.source), isFresh(row, now: now), let rank = row.rank, rank > 0,
          let previous = row.previousRank, let delta = row.rankDelta,
          delta > 0, previous - rank == delta else { return nil }
    return delta
  }

  public static func label(_ rows: [ExternalHeatStore.DisplayRow], now: Date = .now) -> String {
    if rows.isEmpty { return "" }
    let fresh = rows.filter { isFresh($0, now: now) }
    if fresh.isEmpty { return "外部榜单 · 较早记录" }
    let heat = fresh.filter { isHeat($0.source) }
    if !heat.isEmpty { return "热度榜单 · \(Set(heat.map(\.source)).count) 项" }
    return "外部榜单 · \(Set(fresh.map(\.source)).count) 项"
  }
}
