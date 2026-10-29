import Foundation
import SQLite3
import Testing
@testable import WhatShotCore

struct UpcomingWantGroupingTests {
  let helper = UpcomingWishlistTests()
  var now: Date { helper.now }

  func records(_ queue: DatabaseQueue) async throws -> [String: String] {
    try await queue.run { db in
      let stmt = try db.prepare("SELECT release_id,group_id,added_at FROM upcoming_wants")
      defer { sqlite3_finalize(stmt) }
      var values: [String: String] = [:]
      while sqlite3_step(stmt) == SQLITE_ROW {
        values[db.text(stmt, 0)!] = db.text(stmt, 1)! + "|" + String(db.int(stmt, 2)!)
      }
      return values
    }
  }

  @Test func separatelySavedAliasesMergeWithoutRewritingHistoryOrReads() async throws {
    let path = NSTemporaryDirectory() + "want-grouping-\(UUID()).sqlite3"
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
    let queue = try DatabaseQueue(path: path)
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var a = helper.release()
    var b = helper.release(.iqiyi)
    b.title = "测试影片：副标题"
    for row in [a, b] {
      try await store.replace([row], source: row.source, at: now)
      try await wants.setWanted(helper.work([row]), wanted: true, at: now)
    }
    let before = try await records(queue)
    a.releaseDate = "2026-10-31"
    b.releaseDate = "2026-11-01"
    for row in [a, b] { try await store.replace([row], source: row.source, at: now.addingTimeInterval(1)) }
    let aChanges = try await wants.changes(for: [a.id], now: now)
    try await wants.markRead(changeIDs: aChanges.map(\.id))
    let events = try await wants.changes(for: [a.id, b.id], now: now)
    try await UpcomingIdentityGroupingTests().cache([a, b], id: "same", imdb: "tt123", queue: queue)
    for mode in [UpcomingBrowseMode.wanted, .week, .changes] {
      let rows = try await wants.works(mode: mode, sources: [.youku, .iqiyi], externalEnabled: true, now: now)
      #expect(rows.count == 1 && rows[0].releases.count == 2)
      #expect(try await wants.count(mode: mode, sources: [.youku, .iqiyi], externalEnabled: true, now: now) == 1)
    }
    #expect(try await wants.count(mode: .changes, sources: [.youku, .iqiyi], externalEnabled: true, now: now, unreadOnly: true) == 1)
    try await wants.setWanted(helper.work([a, b]), wanted: true, at: now.addingTimeInterval(10))
    #expect(try await records(queue) == before)
    let reopened = UpcomingWishlistStore(queue: try DatabaseQueue(path: path))
    let afterEvents = try await reopened.changes(for: [a.id, b.id], now: now)
    #expect(afterEvents.map(\.id) == events.map(\.id))
    #expect(afterEvents.map(\.isRead) == events.map(\.isRead))
    #expect(try await reopened.count(mode: .wanted, sources: [.youku, .iqiyi], externalEnabled: true, now: now) == 1)
    #expect(try await reopened.count(mode: .wanted, sources: [.youku, .iqiyi], externalEnabled: false, now: now) == 2)
  }

  @Test func unownedSchedulesAreVisibleButDoNotTriggerTodayOrWeekAndFollowStartsNow() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var a = helper.release(date: "2026-11-06")
    var b = helper.release(.tencent, date: "2026-10-28")
    for row in [a, b] { try await store.replace([row], source: row.source, at: now) }
    try await wants.setWanted(helper.work([a]), wanted: true, at: now)
    let original = try await records(queue)
    // 关注腾讯之前曾改档，不能补造这次变动。
    b.releaseDate = "2026-10-29"
    try await store.replace([b], source: .tencent, at: now.addingTimeInterval(1))
    let rows = try await wants.works(mode: .wanted, sources: [.youku, .tencent], now: now)
    #expect(rows.count == 1 && Set(rows[0].releases.map(\.id)) == [a.id, b.id])
    #expect(rows[0].releaseDate == a.releaseDate)
    #expect(try await wants.count(mode: .today, sources: [.youku, .tencent], now: now) == 0)
    #expect(try await wants.count(mode: .week, sources: [.youku, .tencent], now: now) == 0)
    #expect(try await wants.works(mode: .wanted, sources: [.tencent], now: now).isEmpty)
    try await wants.setWanted(rows[0], wanted: true, at: now.addingTimeInterval(2))
    let supplemented = try await records(queue)
    #expect(supplemented[a.id] == original[a.id])
    #expect(supplemented[b.id]?.hasSuffix("|\(Int(now.timeIntervalSince1970) + 2)") == true)
    #expect(try await wants.changes(for: [a.id, b.id], now: now).isEmpty)
    #expect(try await wants.count(mode: .today, sources: [.youku, .tencent], now: now) == 1)
    b.releaseTime = "16:00"
    try await store.replace([b], source: .tencent, at: now.addingTimeInterval(3))
    let changes = try await wants.changes(for: [b.id], now: now)
    #expect(changes.count == 1 && changes[0].reason == "公布时刻")
    // 移出已关注的平台保留最后排期；未关注的同名活跃平台不能恢复它。
    try await wants.setWanted(helper.work([b]), wanted: false)
    a.releaseDate = "2026-10-29"
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(4))
    try await store.replace([helper.release(id: "other", date: nil)], source: .youku, at: now.addingTimeInterval(5))
    #expect(try await wants.savedIDs() == [a.id])
    #expect(try await wants.inactiveIDs(for: [a.id]) == [a.id])
    #expect(try await wants.count(mode: .today, sources: [.youku, .tencent], now: now) == 0)
    #expect(try await wants.count(mode: .changes, sources: [.youku, .tencent], now: now, unreadOnly: true) == 1)
  }

  @Test func cancellationOnlyTouchesExplicitIDsEvenForLegacyGroupAndRollsBackFailure() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var a = helper.release()
    var b = helper.release(.iqiyi)
    for row in [a, b] { try await store.replace([row], source: row.source, at: now) }
    try await wants.setWanted(helper.work([a, b]), wanted: true, at: now)
    a.releaseTime = "10:00"
    b.releaseTime = "12:00"
    for row in [a, b] { try await store.replace([row], source: row.source, at: now.addingTimeInterval(1)) }
    let events = try await wants.changes(for: [a.id, b.id], now: now)
    try await wants.markRead(changeIDs: events.map(\.id))
    try await queue.run { try $0.exec("CREATE TRIGGER fail_want_delete BEFORE DELETE ON upcoming_wants BEGIN SELECT RAISE(ABORT,'test'); END") }
    do {
      try await wants.setWanted(helper.work([a]), wanted: false)
      Issue.record("删除失败应该回滚")
    } catch {}
    #expect(try await wants.savedIDs() == [a.id, b.id])
    #expect(try await wants.changes(for: [a.id, b.id], now: now).allSatisfy(\.isRead))
    #expect(try await wants.changes(for: [a.id, b.id], now: now).count == 2)
    try await queue.run { try $0.exec("DROP TRIGGER fail_want_delete") }
    try await wants.setWanted(helper.work([a]), wanted: false)
    #expect(try await wants.savedIDs() == [b.id])
    #expect(try await wants.changes(for: [a.id], now: now).isEmpty)
    let retained = try await wants.changes(for: [b.id], now: now)
    #expect(retained.count == 1 && retained[0].isRead)
    #expect(try await wants.count(mode: .wanted, sources: [.youku], now: now) == 0)
    #expect(try await wants.count(mode: .wanted, sources: [.iqiyi], now: now) == 1)
  }

  @Test func mergedCountsAndPaginationRemainConsistentAcrossFilters() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    let a = (0..<65).map { index in
      var row = helper.release(id: "y\(index)", date: "2026-10-29")
      row.title = "电影\(index)"
      return row
    }
    let b = a.enumerated().map { index, row in
      var other = row
      other.source = .iqiyi
      other.sourceID = "i\(index)"
      return other
    }
    try await store.replace(a, source: .youku, at: now)
    try await store.replace(b, source: .iqiyi, at: now)
    // 模拟历史上分别关注的平台组。
    for row in a + b { try await wants.setWanted(helper.work([row]), wanted: true, at: now) }
    for mode in [UpcomingBrowseMode.wanted, .today, .week] {
      #expect(try await wants.count(mode: mode, sources: [.youku, .iqiyi], now: now) == 65)
      let first = try await wants.works(mode: mode, sources: [.youku, .iqiyi], now: now)
      let next = try await wants.works(mode: mode, sources: [.iqiyi, .youku], now: now, offset: 60)
      #expect(first.count == 60 && next.count == 5)
      #expect(Set((first + next).map(\.id)).count == 65)
      #expect((first + next).allSatisfy { $0.releases.count == 2 })
    }
    #expect(try await wants.count(mode: .today, sources: [.youku, .iqiyi], region: "US", now: now) == 0)
    #expect(try await wants.count(mode: .today, sources: [.youku, .iqiyi], kind: "series", now: now) == 0)
  }
}
