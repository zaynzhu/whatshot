import Foundation
import Testing
@testable import WhatShotCore

struct OverseasDigitalTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-28T00:30:00Z")!

  static func page(id: Int = 32429, slug: String = "primetime-2026", title: String = "Primetime (2026)", html: String) -> [String: Any] {
    ["id": id, "slug": slug, "link": "https://whentostream.com/\(slug)/",
     "title": ["rendered": title], "content": ["rendered": html]]
  }

  static func calendar(_ month: OverseasDigitalParser.Month, date: String, empty: Bool = false) -> [String: Any] {
    page(slug: month.slug, title: "Streaming – VOD/Digital Only", html: """
    <a href="https://whentostream.com/\(month.slug)/">月份导航</a>
    <h2 class="wp-block-heading">\(date)</h2>
    \(empty ? "" : "<figure><a href=\"https://whentostream.com/primetime-2026/\"><img data-image-title=\"Primetime 10\" src=\"https://i0.wp.com/poster.jpg?w=640&amp;ssl=1\"></a></figure>")
    """)
  }

  @Test func calendarAndDetailKeepIdentityPrecisionAndReleaseType() throws {
    let month = OverseasDigitalParser.months(at: now)[2]
    let calendar = Self.calendar(month, date: "November 3, 2026")
    let candidate = try #require(OverseasDigitalParser.candidates(calendar, month: month).first)
    var withUnlinked = calendar
    var content = withUnlinked["content"] as! [String: Any]
    content["rendered"] = (content["rendered"] as! String) + "<figure><img data-image-title='猜不出的片名 10' src='https://i0.wp.com/unknown.jpg'></figure>"
    withUnlinked["content"] = content
    #expect(try OverseasDigitalParser.candidates(withUnlinked, month: month).count == 1)
    let detail = Self.page(title: "Primetime &amp; &#8220;Friends&#8221; (2026)", html: """
      <p>Theater Date: September 25, 2026</p>
      <p>Pre-order: October 20, 2026</p>
      <p><strong>PVOD Release Date</strong>: November 3, 2026</p>
      <p><strong>SVOD Release Date</strong>: December 1, 2026 (Hulu)</p>
      <script>const sample = '<p>VOD Release Date: January 1, 2000</p>'</script>
      """)
    let row = try OverseasDigitalParser.release(detail, candidate: candidate, observedAt: now)
    #expect(row.title == "Primetime & “Friends” (2026)")
    #expect(row.sourceID == "32429")
    #expect(row.releaseDate == "2026-11-03")
    #expect(row.releaseTime == nil && row.timeZone.isEmpty)
    #expect(row.region == "US" && row.releaseType == "digital")
    #expect(row.rawSchedule.contains("官宣状态未核实"))
    #expect(!row.sourceReportsAvailable)
    #expect(row.posterURL == "https://i0.wp.com/poster.jpg?w=640&ssl=1")
    let changed = Self.page(html: "<p>PVOD Release Date: November 10, 2026</p>")
    #expect(try OverseasDigitalParser.release(changed, candidate: candidate, observedAt: now).releaseDate == "2026-11-10")
    let withdrawn = Self.page(html: "<p>PVOD Release Date: TBA</p>")
    #expect(try OverseasDigitalParser.release(withdrawn, candidate: candidate, observedAt: now).releaseDate == nil)
  }

  @Test func malformedOrSubscriptionOnlyDataNeverBecomesDigitalDate() throws {
    let month = OverseasDigitalParser.months(at: now)[2]
    let candidate = try #require(OverseasDigitalParser.candidates(Self.calendar(month, date: "November 3, 2026"), month: month).first)
    for html in ["<p>SVOD Release Date: November 3, 2026</p>",
                 "<p>PVOD Release Date: February 30, 2026</p>",
                 "<p>PVOD Release Date: November 3, 2026 or November 10, 2026</p>",
                 "<p>VOD Release Date: November 3, 2026</p><p>PVOD Release Date: November 4, 2026</p>",
                 "<p>Theater Date: November 3, 2026</p>"] {
      #expect(throws: UpcomingError.self) { try OverseasDigitalParser.release(Self.page(html: html), candidate: candidate, observedAt: now) }
    }
    #expect(throws: UpcomingError.self) {
      try OverseasDigitalParser.release(Self.page(slug: "different", html: "<p>VOD Release Date: November 3, 2026</p>"), candidate: candidate, observedAt: now)
    }
    #expect(throws: UpcomingError.self) {
      try OverseasDigitalParser.candidates(Self.calendar(month, date: "November 31, 2026"), month: month)
    }
    #expect(throws: UpcomingError.self) {
      try OverseasDigitalParser.candidates(Self.calendar(month, date: "October 3, 2026"), month: month)
    }
  }

  @Test func regionWindowsUseLocalDatesAndValidEmptySnapshotClearsOnlyOverseas() async throws {
    #expect(UpcomingDate.day(now) == "2026-10-28")
    #expect(UpcomingDate.day(now, region: "US") == "2026-10-27")
    let yearEnd = ISO8601DateFormatter().date(from: "2026-12-31T12:00:00Z")!
    #expect(OverseasDigitalParser.months(at: yearEnd)[2].lastDay == "2027-01-31")
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    let foreign = UpcomingRelease(source: .whenToStream, sourceID: "123", kind: "movie", title: "同名",
      sourceURL: "https://whentostream.com/film/", region: "US", timeZone: "", releaseType: "digital",
      releaseDate: "2026-10-27", rawSchedule: "报道", observedAt: now)
    let domestic = UpcomingRelease(source: .youku, sourceID: "456", kind: "movie", title: "同名",
      sourceURL: "https://youku.com/", releaseDate: "2026-10-28", rawSchedule: "平台", observedAt: now)
    try await store.replace([foreign], source: .whenToStream, at: now)
    try await store.replace([domestic], source: .youku, at: now)
    let us = try await store.works(sources: UpcomingSource.allCases, region: "US", now: now)
    #expect(us.count == 1 && us[0].releaseDate == "2026-10-27")
    #expect(us[0].releases.count == 1 && us[0].releases[0].region == "US")
    #expect(try await store.works(sources: UpcomingSource.allCases, region: "CN", now: now).count == 1)
    let combined = try await store.works(sources: UpcomingSource.allCases, now: now)
    #expect(combined.map(\.releaseDate) == ["2026-10-27", "2026-10-28"])
    #expect(combined.map { $0.releases.first?.region } == ["US", "CN"])
    try await store.replace([], source: .whenToStream, at: now)
    #expect(try await store.works(sources: UpcomingSource.allCases, region: "US", now: now).isEmpty)
    #expect(try await store.works(sources: UpcomingSource.allCases, region: "CN", now: now).count == 1)
  }

  private func release(_ source: UpcomingSource, id: String, date: String?) -> UpcomingRelease {
    UpcomingRelease(source: source, sourceID: id, kind: "movie", title: id,
      sourceURL: "https://example.com/\(id)", region: source.region,
      timeZone: source == .whenToStream ? "" : "Asia/Shanghai",
      releaseType: source == .whenToStream ? "digital" : "platform",
      releaseDate: date, rawSchedule: "测试排期", observedAt: now)
  }

  @Test func combinedWindowsUseEachRegionsTodayAndPastBoundary() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    try await store.replace([
      release(.youku, id: "国内过期", date: "2026-10-13"),
      release(.youku, id: "国内边界", date: "2026-10-14"),
      release(.youku, id: "国内昨天", date: "2026-10-27"),
      release(.youku, id: "国内今天", date: "2026-10-28"),
      release(.youku, id: "国内待定", date: nil)
    ], source: .youku, at: now)
    try await store.replace([
      release(.whenToStream, id: "美国过期", date: "2026-10-12"),
      release(.whenToStream, id: "美国边界", date: "2026-10-13"),
      release(.whenToStream, id: "美国昨天", date: "2026-10-26"),
      release(.whenToStream, id: "美国今天", date: "2026-10-27"),
      release(.whenToStream, id: "美国待定", date: nil)
    ], source: .whenToStream, at: now)
    for (window, titles) in [
      (UpcomingWindow.future, ["美国今天", "国内今天"]),
      (.recent, ["国内昨天", "美国昨天", "国内边界", "美国边界"]),
      (.undated, ["国内待定", "美国待定"])
    ] {
      let works = try await store.works(sources: UpcomingSource.allCases, window: window, now: now)
      let rows = try await store.releases(sources: UpcomingSource.allCases, window: window, now: now)
      #expect(works.map(\.title) == titles)
      #expect(rows.map(\.title) == titles)
    }
    #expect(try await store.works(sources: [.whenToStream], now: now).map(\.title) == ["美国今天"])
    #expect(try await store.works(sources: [.youku], now: now).map(\.title) == ["国内今天"])
  }

  @Test func combinedPaginationGroupsPlatformsBeforePagingAcrossRegions() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    for source in [UpcomingSource.youku, .iqiyi, .whenToStream] {
      try await store.replace((0..<35).map {
        release(source, id: "电影\(String(format: "%02d", $0))", date: "2026-10-30")
      }, source: source, at: now)
    }
    let first = try await store.works(sources: UpcomingSource.allCases, now: now)
    let second = try await store.works(sources: UpcomingSource.allCases, now: now, offset: 60)
    #expect(first.count == 60 && second.count == 10)
    let all = first + second
    #expect(Set(all.map(\.id)).count == 70)
    #expect(all.filter { $0.releases.count == 2 }.count == 35)
    #expect(all.filter { $0.releases.first?.region == "US" }.count == 35)
    #expect(first.prefix(2).map { $0.releases.first?.region } == ["CN", "US"])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["WHATSHOT_LIVE_OVERSEAS"] == "1"))
  func liveOverseasDigital() async throws {
    let rows = try await UpcomingClient().fetch(.whenToStream)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.region == "US" && $0.releaseType == "digital" && $0.releaseTime == nil })
    #expect(Set(rows.map(\.id)).count == rows.count)
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    try await store.replace(rows, source: .whenToStream, at: .now)
    let works = try await store.works(sources: [.whenToStream], region: "US")
    print("美区数字发行：\(rows.count) 条，今日与未来 \(works.count) 部，均为报道日期")
    for row in rows.sorted(by: { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }).suffix(8) {
      print("\(row.title) · \(row.releaseDate ?? "待定档") · \(row.timeText)")
    }
  }
}
