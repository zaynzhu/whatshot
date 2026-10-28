import Foundation
import Testing
@testable import WhatShotCore

struct UpcomingTests {
  private let now = ISO8601DateFormatter().date(from: "2026-10-27T16:01:00Z")!

  @Test func datesRespectShanghaiAndPrecision() {
    let cases: [(String, String?, String?)] = [
      ("明天16:00上线", "2026-10-29", "16:00"), ("今天9:05上线", "2026-10-28", "09:05"),
      ("10月27日 10:00上线", "2026-10-27", "10:00"), ("10月30日", "2026-10-30", nil),
      ("敬请期待", nil, nil), ("16:00上线", nil, nil), ("2月30日", nil, nil),
      ("2028年2月29日 24:99", "2028-02-29", nil), ("2026年2月29日", nil, nil)
    ]
    for (raw, date, time) in cases {
      let result = UpcomingDate.parse(raw, observedAt: now)
      #expect(result.date == date)
      #expect(result.time == time)
    }
    let yearEnd = ISO8601DateFormatter().date(from: "2026-12-31T00:00:00Z")!
    #expect(UpcomingDate.parse("明天10:00", observedAt: yearEnd).date == "2027-01-01")
    #expect(UpcomingDate.parse("1月2日", observedAt: yearEnd).date == "2027-01-02")
    #expect(UpcomingDate.parse("12月30日", observedAt: yearEnd).date == "2026-12-30")
  }

  @Test func nuxtDecodesLiteralsWithoutExecutingExpressions() throws {
    let html = #"<script>window.__NUXT__=(function(a,b,c){return {data:[{name:a,id:b,empty:c,text:"引号\"与\\"}]}}("片名",1234567890123,void 0));</script>"#
    let decoded = try NuxtLiteral.decode(html)
    let item = (decoded["data"] as? [[String: Any]])?.first
    #expect(item?["name"] as? String == "片名")
    #expect((item?["id"] as? NSNumber)?.int64Value == 1234567890123)
    for expression in ["alert(1)", "window.location", "1+2", "(function(){return 1})()", "{a:1,a:2}"] {
      #expect(throws: (any Error).self) {
        try NuxtLiteral.decode("<script>window.__NUXT__=(function(){return {x:\(expression)}}());</script>")
      }
    }
  }

  @Test func sourceSemanticsAndHTTPS() throws {
    let rows = try UpcomingClient.parseYoukuNodes([
      ["data": ["title": "杂卡", "action": ["type": "JUMP_TO_SHOW", "value": "old"]]],
      ["data": ["title": "预约", "reserve": ["id": "new"], "action": ["type": "JUMP_TO_SHOW", "value": "new"],
                "reason": ["text": ["title": "明天16:00上线"]]]]
    ], kind: "movie", observedAt: now)
    #expect(rows.count == 1)
    #expect(rows.first?.releaseTime == "16:00")
    let tencent = try UpcomingClient.parseTencentCard(["cid": "abc", "title": "旧影院日期", "publish_date": "2026-01-01"], kind: "movie", observedAt: now)
    #expect(tencent.releaseDate == nil)
    #expect(UpcomingClient.posterURL("http://m.ykimg.com/a.jpg", source: .youku) == "https://m.ykimg.com/a.jpg")
    #expect(UpcomingClient.posterURL("http://unknown.example/a.jpg", source: .youku) == nil)
    #expect(UpcomingClient.posterURL("http://ykimg.com.evil.example/a.jpg", source: .youku) == nil)
    let stale = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
      headerFields: ["Date": "Tue, 27 Oct 2026 00:00:00 GMT"])!
    #expect(throws: UpcomingError.self) { try UpcomingClient.observationDate(stale, now: now) }
  }

  @Test func iqiyiKeepsUndatedIdentityWithoutInventingDetailURL() throws {
    let html = #"<script>window.__NUXT__=(function(a,b){return {data:[{allVideos:[{cid:1,id:1234567890123456,name:"未建详情页",publishText:"即将上线",pageUrl:a,isOnline:b},{cid:2,id:2345678901234567,name:"仅日期",publishText:"10月30日上线",pageUrl:"//www.iqiyi.com/v_fixture.html",isOnline:b}]}]}}(null,false));</script>"#
    let rows = try UpcomingClient.parseIqiyi(html, observedAt: now)
    let undated = rows.first { $0.kind == "movie" }
    #expect(undated?.sourceID == "1234567890123456")
    #expect(undated?.sourceURL == "https://www.iqiyi.com/newOnlinePCW")
    #expect(undated?.releaseDate == nil)
    #expect(rows.first { $0.kind == "series" }?.releaseDate == "2026-10-30")
    #expect(rows.allSatisfy { $0.releaseTime == nil })
  }

  @Test func oldSettingsDecodeAndExplicitDisabledSourcesPersist() throws {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ButaiSettings.default)) as! [String: Any]
    object.removeValue(forKey: "upcomingSources")
    var settings = try JSONDecoder().decode(ButaiSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(settings.enabledUpcomingSources == UpcomingSource.allCases)
    settings.upcomingSources = []
    let reloaded = try JSONDecoder().decode(ButaiSettings.self, from: JSONEncoder().encode(settings))
    #expect(reloaded.enabledUpcomingSources.isEmpty)
  }

  private func row(_ id: String, source: UpcomingSource = .youku, date: String? = "2026-10-29", time: String? = nil) -> UpcomingRelease {
    UpcomingRelease(source: source, sourceID: id, kind: "movie", title: "同名作品", sourceURL: "https://example.com/\(id)",
      releaseDate: date, releaseTime: time, rawSchedule: "来源原文", observedAt: now)
  }

  @Test func snapshotWithdrawalIsolationFailureAndRollback() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    try await store.replace([row("a"), row("b", time: "12:00")], source: .youku, at: now)
    try await store.replace([row("a", source: .iqiyi)], source: .iqiyi, at: now)
    #expect(try await store.releases(sources: [.youku], now: now).map(\.sourceID) == ["b", "a"])
    try await queue.run { db in
      try db.exec("CREATE TRIGGER reject_upcoming BEFORE INSERT ON upcoming_releases WHEN NEW.title='拒绝' BEGIN SELECT RAISE(ABORT, 'simulated'); END")
    }
    var rejected = row("bad")
    rejected.title = "拒绝"
    let batch = [row("a", date: nil), rejected]
    await #expect(throws: (any Error).self) { try await store.replace(batch, source: .youku, at: now) }
    #expect(try await store.releases(sources: [.youku], now: now).count == 2)
    try await store.recordFailure(.youku, message: "超时", at: now.addingTimeInterval(10))
    let state = try await store.states().first { $0.source == .youku }
    #expect(state?.count == 2)
    #expect(state?.lastSuccessAt == now)
    #expect(state?.error == "超时")
    try await store.replace([row("a", date: nil)], source: .youku, at: now.addingTimeInterval(20))
    #expect(try await store.releases(sources: [.youku], now: now).isEmpty)
    #expect(try await store.releases(sources: [.youku], window: .undated, now: now).map(\.sourceID) == ["a"])
    #expect(try await store.releases(sources: [.iqiyi], now: now).count == 1)
    #expect(try await store.releases(sources: [], now: now).isEmpty)
    await #expect(throws: UpcomingError.self) { try await store.replace([], source: .youku, at: now) }
    await #expect(throws: UpcomingError.self) { try await store.replace([row("a"), row("a")], source: .youku, at: now) }
  }

  @Test func localPaginationAndRecentWindow() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    let rows = (0..<65).map { row(String(format: "%03d", $0)) } + [row("old", date: "2026-10-27")]
    try await store.replace(rows, source: .youku, at: now)
    #expect(try await store.releases(sources: [.youku], now: now).count == 60)
    #expect(try await store.releases(sources: [.youku], now: now, offset: 60).count == 5)
    #expect(try await store.releases(sources: [.youku], window: .recent, now: now).map(\.sourceID) == ["old"])
  }

  @Test func syncIsolatesFailuresAndSkipsDisabledOrFreshSources() async throws {
    actor Calls {
      var sources: [UpcomingSource] = []
      func add(_ source: UpcomingSource) { sources.append(source) }
    }
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    let calls = Calls()
    let seed = row("old")
    try await store.replace([seed], source: .youku, at: now)
    let iqiyi = row("new", source: .iqiyi)
    let sync = UpcomingSync(store: store) { source in
      await calls.add(source)
      if source == .youku { throw UpcomingError("测试失败") }
      return [iqiyi]
    }
    try await sync.run(sources: [.youku, .iqiyi], force: false, intervalHours: 0)
    #expect(await calls.sources.isEmpty)
    try await sync.run(sources: [], force: true, intervalHours: 6)
    #expect(await calls.sources.isEmpty)
    try await sync.run(sources: [.youku, .iqiyi], force: true, intervalHours: 6)
    #expect(await calls.sources == [.youku, .iqiyi])
    #expect(try await store.releases(sources: [.youku], now: now).first == seed)
    #expect(try await store.releases(sources: [.iqiyi], now: now).first == iqiyi)
    try await sync.run(sources: [.iqiyi], force: false, intervalHours: 6)
    #expect(await calls.sources.count == 2)
    let cancelSync = UpcomingSync(store: store) { _ in
      try await Task.sleep(for: .seconds(60))
      return [iqiyi]
    }
    let task = Task { try await cancelSync.run(sources: [.iqiyi], force: true, intervalHours: 6) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.releases(sources: [.iqiyi], now: now).first == iqiyi)
    #expect(try await store.states().first(where: { $0.source == .iqiyi })?.error == nil)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["WHATSHOT_LIVE_UPCOMING"] == "1"))
  func liveAnonymousSources() async throws {
    let client = UpcomingClient()
    for source in UpcomingSource.allCases {
      do {
        let rows = try await client.fetch(source)
        #expect(!rows.isEmpty)
        print("待播验证 \(source.title): 总数 \(rows.count)，日期 \(rows.filter { $0.releaseDate != nil }.count)，时分 \(rows.filter { $0.releaseTime != nil }.count)")
        for row in rows.filter({ $0.releaseDate != nil }).prefix(5) {
          print("\(row.title) · \(row.releaseDate ?? "") · \(row.timeText) · \(row.rawSchedule)")
        }
        let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
        try await store.replace(rows, source: source, at: .now)
      } catch {
        Issue.record("\(source.title)：\(error.localizedDescription)")
      }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["WHATSHOT_IQIYI_FIXTURE"] != nil))
  func localIqiyiSnapshot() throws {
    let path = ProcessInfo.processInfo.environment["WHATSHOT_IQIYI_FIXTURE"]!
    let html = try String(contentsOfFile: path, encoding: .utf8)
    #expect(try UpcomingClient.parseIqiyi(html, observedAt: now).count > 0)
  }
}
