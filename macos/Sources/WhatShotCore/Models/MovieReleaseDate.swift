import Foundation

/// 电影独立口径：从站方原始上映信息提取公映／网络上线候选，不采用特殊场次。
public enum MovieReleaseDate {
  private static let datePattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9])\s*[（(]([^()（）]+)[)）]"#
  )
  private static let specialScreening = try! NSRegularExpression(
    pattern: "电影节|影展|电影展|电影周|首映|点映|重映|festival|premiere|preview|re-release",
    options: .caseInsensitive
  )

  public static func parse(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let text = raw as NSString
    return datePattern.matches(in: raw, range: NSRange(location: 0, length: text.length))
      .compactMap { match -> String? in
        let label = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              specialScreening.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) == nil else {
          return nil
        }
        let date = text.substring(with: match.range(at: 1))
        return isValid(date) ? date : nil
      }
      .min()
  }

  /// 严格公历校验，拒绝系统日历自动把 2 月 30 日进位到 3 月。
  static func isValid(_ date: String) -> Bool {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, parts[0] >= 1800 else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard let value = calendar.date(from: components) else { return false }
    let result = calendar.dateComponents([.year, .month, .day], from: value)
    return result.year == parts[0] && result.month == parts[1] && result.day == parts[2]
  }
}
