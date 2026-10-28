import Foundation

public enum UpcomingSource: String, CaseIterable, Codable, Sendable, Identifiable {
  case youku, iqiyi, tencent
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .youku: return "优酷"
    case .iqiyi: return "爱奇艺"
    case .tencent: return "腾讯视频"
    }
  }
}

/// 平台排期独立于作品首播日；未知时刻不是午夜。
public struct UpcomingRelease: Codable, Equatable, Sendable, Identifiable {
  public var source: UpcomingSource
  public var sourceID: String
  public var kind: String
  public var title: String
  public var posterURL: String?
  public var sourceURL: String
  public var region = "CN"
  public var timeZone = "Asia/Shanghai"
  public var releaseType = "platform"
  public var releaseDate: String?
  public var releaseTime: String?
  public var rawSchedule: String
  public var sourceReportsAvailable = false
  public var observedAt: Date

  public var id: String { "\(source.rawValue)|\(sourceID)|\(kind)|\(region)|\(releaseType)" }
  public var timeText: String { releaseDate == nil ? "待定档" : (releaseTime ?? "时间待公布") }
}

public enum UpcomingWindow: String, CaseIterable, Sendable {
  case future = "今日与未来"
  case undated = "待定档"
  case recent = "近期排期"
}

/// 展示分组，不修改来源身份；平台排期独立保留，不能互相借用时刻。
public struct UpcomingWork: Identifiable, Sendable {
  public let id: String
  public let releaseDate: String?
  public let releases: [UpcomingRelease]
  public var title: String { releases.first?.title ?? "" }
  public var kind: String { releases.first?.kind ?? "" }
  public var posterURL: String? { releases.compactMap(\.posterURL).first }
}

public struct UpcomingSourceState: Equatable, Sendable {
  public var source: UpcomingSource
  public var lastAttemptAt: Date?
  public var lastSuccessAt: Date?
  public var count: Int
  public var error: String?
}

public struct UpcomingError: LocalizedError, Sendable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public enum UpcomingDate {
  public static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return value
  }

  public static func day(_ value: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: value)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  /// 月日只在邻近跨年窗口推断年份，过远日期保留原文，不制造下一年排期。
  static func parse(_ text: String, observedAt: Date) -> (date: String?, time: String?) {
    let today = calendar.startOfDay(for: observedAt)
    var date: String?
    if text.contains("今天") || text.contains("今日") {
      date = day(today)
    } else if text.contains("明天") || text.contains("明日") {
      date = day(calendar.date(byAdding: .day, value: 1, to: today)!)
    } else if let match = captures(#"(?<![0-9])(?:([0-9]{4})年)?([0-9]{1,2})月([0-9]{1,2})日"#, text) {
      let explicitYear = Int(match[0])
      let month = Int(match[1])!
      let dom = Int(match[2])!
      let current = calendar.dateComponents([.year, .month], from: today)
      var year = explicitYear ?? current.year!
      if explicitYear == nil {
        if current.month! >= 11 && month <= 2 { year += 1 }
        if current.month! <= 2 && month >= 11 { year -= 1 }
      }
      let candidate = String(format: "%04d-%02d-%02d", year, month, dom)
      if MovieReleaseDate.isValid(candidate),
         let value = calendar.date(from: DateComponents(year: year, month: month, day: dom)),
         explicitYear != nil || abs(value.timeIntervalSince(today)) <= 183 * 86400 {
        date = candidate
      }
    }
    guard let date else { return (nil, nil) }
    var time: String?
    if let parts = captures(#"(?<![0-9])([0-9]{1,2}):([0-9]{2})(?![0-9])"#, text),
       let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 {
      time = String(format: "%02d:%02d", hour, minute)
    }
    return (date, time)
  }

  private static func captures(_ pattern: String, _ text: String) -> [String]? {
    let regex = try! NSRegularExpression(pattern: pattern)
    let value = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: value.length)) else { return nil }
    return (1..<match.numberOfRanges).map {
      match.range(at: $0).location == NSNotFound ? "" : value.substring(with: match.range(at: $0))
    }
  }
}
