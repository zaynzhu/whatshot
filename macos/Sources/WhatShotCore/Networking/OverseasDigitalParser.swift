import Foundation

/// 仅解析站方 REST 返回的数据与受限 HTML 片段，不执行脚本或加载网页资源。
enum OverseasDigitalParser {
  struct Month {
    let slug: String
    let prefix: String
    let lastDay: String
  }

  struct Candidate {
    let slug: String
    let url: String
    let date: String
    let poster: String?
  }

  static func months(at now: Date) -> [Month] {
    let calendar = UpcomingDate.calendar(region: "US")
    let current = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMMM-yyyy"
    return (-1...1).map { offset in
      let date = calendar.date(byAdding: .month, value: offset, to: current)!
      let next = calendar.date(byAdding: .month, value: 1, to: date)!
      return Month(slug: "streaming-\(formatter.string(from: date).lowercased())-vod-digital-only",
        prefix: String(UpcomingDate.day(date, region: "US").prefix(7)),
        lastDay: UpcomingDate.day(calendar.date(byAdding: .day, value: -1, to: next)!, region: "US"))
    }
  }

  static func lowerBound(at now: Date) -> String {
    UpcomingDate.day(UpcomingDate.calendar(region: "US").date(byAdding: .day, value: -14, to: now)!, region: "US")
  }

  static func candidates(_ page: [String: Any], month: Month, lowerBound: String? = nil) throws -> [Candidate] {
    guard page["slug"] as? String == month.slug,
          let title = (page["title"] as? [String: Any])?["rendered"] as? String,
          plain(title).contains("VOD/Digital Only"),
          let html = (page["content"] as? [String: Any])?["rendered"] as? String,
          !html.isEmpty, html.contains(month.slug.replacingOccurrences(of: "-vod-digital-only", with: "")) else {
      throw UpcomingError("美区数字发行日历结构变化")
    }
    var day: String?
    var result: [Candidate] = []
    var eligibleImages = 0
    for token in matches(#"(?is)<h2\b[^>]*>.*?</h2>|<figure\b[^>]*>.*?</figure>"#, withoutScripts(html)) {
      if token.lowercased().hasPrefix("<h2") {
        let heading = plain(token).replacingOccurrences(of: " ,", with: ",")
        day = date(heading)
        if day == nil && heading.range(of: #"^(January|February|March|April|May|June|July|August|September|October|November|December)\b"#, options: .regularExpression) != nil {
          throw UpcomingError("美区日历日期格式变化")
        }
        if let day, !day.hasPrefix(month.prefix + "-") { throw UpcomingError("美区日历日期与月份不符") }
        continue
      }
      guard let day else { continue }
      if let lowerBound, day < lowerBound { continue }
      guard let image = matches(#"(?is)<img\b[^>]*>"#, token).first else { continue }
      eligibleImages += 1
      // 原站有只有海报、尚无详情入口的卡片；图片名带编号，不猜标题和作品身份。
      guard let anchor = matches(#"(?is)<a\b[^>]*>"#, token).first else { continue }
      guard
            let rawURL = attribute("href", in: anchor), let url = pageURL(rawURL),
            let slug = URL(string: url)?.path.split(separator: "/").last.map(String.init),
            slug.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
        throw UpcomingError("美区日历影片身份缺失")
      }
      let poster = attribute("src", in: image).flatMap { raw -> String? in
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
      }
      result.append(Candidate(slug: slug, url: url, date: day, poster: poster))
    }
    guard eligibleImages == 0 || !result.isEmpty else { throw UpcomingError("美区日历未返回可核对身份的影片") }
    return result
  }

  static func release(_ page: [String: Any], candidate: Candidate, observedAt: Date) throws -> UpcomingRelease {
    guard let id = page["id"] as? NSNumber, id.intValue > 0,
          page["slug"] as? String == candidate.slug,
          let rawLink = page["link"] as? String, let link = pageURL(rawLink), link == candidate.url,
          let renderedTitle = (page["title"] as? [String: Any])?["rendered"] as? String,
          !plain(renderedTitle).isEmpty,
          let html = (page["content"] as? [String: Any])?["rendered"] as? String else {
      throw UpcomingError("美区影片详情身份或标题缺失")
    }
    // 前缀锚定，SVOD、影院和预购字段均不能成为本次发行日期。
    let schedules = matches(#"(?is)<p\b[^>]*>.*?</p>"#, withoutScripts(html)).map(plain).filter {
      $0.range(of: #"^P?VOD Release Date\s*:"#, options: .regularExpression) != nil
    }
    guard schedules.count == 1, let raw = schedules.first else {
      throw UpcomingError("美区详情缺少唯一数字付费排期")
    }
    let value = raw.replacingOccurrences(of: #"^P?VOD Release Date\s*:\s*"#, with: "", options: .regularExpression)
    let releaseDate = date(value)
    guard releaseDate != nil || ["tba", "tbd", "to be announced"].contains(value.lowercased()) else {
      throw UpcomingError("美区数字付费日期格式变化")
    }
    var row = UpcomingRelease(source: .whenToStream, sourceID: id.stringValue, kind: "movie",
      title: plain(renderedTitle), posterURL: candidate.poster, sourceURL: link,
      region: "US", timeZone: "", releaseType: "digital", releaseDate: releaseDate, releaseTime: nil,
      rawSchedule: "媒体报道 · 官宣状态未核实 · \(raw) · 日历原列 \(candidate.date)", observedAt: observedAt)
    let title = plain(renderedTitle)
    if let yearSuffix = matches(#"\([12][0-9]{3}\)$"#, title).first {
      row.productionYear = Int(yearSuffix.dropFirst().dropLast())
      row.originalTitle = String(title.dropLast(yearSuffix.count)).trimmingCharacters(in: .whitespaces)
    }
    let directorLines = matches(#"(?is)<p\b[^>]*>.*?</p>"#, withoutScripts(html)).map(plain).filter { $0.range(of: #"^Directors?\s*:"#, options: .regularExpression) != nil }
    if directorLines.count == 1 {
      let names = directorLines[0].replacingOccurrences(of: #"^Directors?\s*:\s*"#, with: "", options: .regularExpression)
      row.directors = names.components(separatedBy: " and ").flatMap { $0.components(separatedBy: ",") }
        .flatMap { $0.components(separatedBy: " & ") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    return row
  }

  private static func date(_ value: String) -> String? {
    guard let raw = matches(#"^(?:January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{1,2}, [0-9]{4}(?![0-9])"#, value).first else { return nil }
    let suffix = value.dropFirst(raw.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard suffix.isEmpty || suffix.range(of: #"^\([^0-9]*\)$"#, options: .regularExpression) != nil else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMMM d, yyyy"
    formatter.isLenient = false
    guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private static func pageURL(_ raw: String) -> String? {
    guard let url = URL(string: raw), url.scheme == "https", url.host == "whentostream.com",
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.path.split(separator: "/").count == 1 else { return nil }
    return "https://whentostream.com/\(url.path.split(separator: "/")[0])/"
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let pattern = "(?is)\\s" + name + #"\s*=\s*(["'])(.*?)\1"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let string = tag as NSString
    guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: string.length)) else { return nil }
    return entities(string.substring(with: match.range(at: 2)))
  }

  private static func matches(_ pattern: String, _ value: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let string = value as NSString
    return regex.matches(in: value, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
  }

  private static func plain(_ value: String) -> String {
    let stripped = withoutScripts(value)
      .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
    return entities(stripped).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func withoutScripts(_ value: String) -> String {
    value.replacingOccurrences(of: #"(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)>"#, with: "", options: .regularExpression)
  }

  private static func entities(_ value: String) -> String {
    let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
      "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "ndash": "–", "mdash": "—", "hellip": "…"]
    let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)
    let text = value as NSString
    var result = value
    for match in regex.matches(in: value, range: NSRange(location: 0, length: text.length)).reversed() {
      let key = text.substring(with: match.range(at: 1))
      let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : (key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil)
      let replacement = number.flatMap(UnicodeScalar.init).map(String.init) ?? named[key]
      if let replacement, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
    }
    return result
  }
}
