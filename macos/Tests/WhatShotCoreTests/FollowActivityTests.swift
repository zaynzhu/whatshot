import Foundation
import SQLite3

import Testing
@testable import WhatShotCore

struct FollowActivityTests {
  let helper = UpcomingWishlistTests()

  @Test func countsUseWholeGroupsAndRegionalTodayBeforePagination() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    let now = ISO8601DateFormatter().date(from: "2026-10-29T01:00:00Z")!
    let rows = (1...65).map { helper.release(id: "\($0)", date: "2026-10-29") }
    try await store.replace(rows, source: .youku, at: now)
    for row in rows { try await wants.setWanted(helper.work([row]), wanted: true, at: now) }
    let anotherPlatform = helper.release(.tencent, date: "2026-10-29")
    try await store.replace([anotherPlatform], source: .tencent, at: now)
    try await wants.setWanted(helper.work([rows[0], anotherPlatform]), wanted: true, at: now)
    let us = helper.release(.whenToStream, date: "2026-10-28")
    try await store.replace([us], source: .whenToStream, at: now)
    try await wants.setWanted(helper.work([us]), wanted: true, at: now)
    let sources: [UpcomingSource] = [.youku, .tencent, .whenToStream]
    #expect(try await wants.count(mode: .today, sources: sources, now: now) == 66)
    #expect(try await wants.count(mode: .week, sources: sources, now: now) == 66)
    #expect(try await wants.works(mode: .today, sources: sources, now: now).count == 60)
    #expect(try await wants.works(mode: .today, sources: sources, now: now, offset: 60).count == 6)
    #expect(try await wants.count(mode: .today, sources: sources, region: "US", now: now) == 1)
    #expect(try await wants.count(mode: .today, sources: sources, kind: "series", now: now) == 0)
    #expect(try await wants.count(mode: .today, sources: [], now: now) == 0)
    #expect(try await wants.count(mode: .changes, sources: sources, now: now, unreadOnly: true) == 0)
  }

  @Test func readIDsDoNotConsumeConcurrentChangesAndPersistAcrossReopen() async throws {
    let path = NSTemporaryDirectory() + "activity-\(UUID()).sqlite3"
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
    let queue = try DatabaseQueue(path: path)
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var row = helper.release()
    let now = helper.now
    try await store.replace([row], source: .youku, at: now)
    try await wants.setWanted(helper.work([row]), wanted: true, at: now)
    row.releaseDate = "2026-10-31"
    try await store.replace([row], source: .youku, at: now.addingTimeInterval(1))
    let displayed = try await wants.changes(for: [row.id], now: now)
    #expect(displayed.count == 1 && !displayed[0].isRead)
    #expect(displayed[0].label == "延期上线")
    row.releaseDate = "2026-10-30"
    // 同一秒也按事件 ID 区分，不能用时间水位吞掉新事件。
    try await store.replace([row], source: .youku, at: now.addingTimeInterval(1))
    try await wants.markRead(changeIDs: displayed.map(\.id))
    let reopened = UpcomingWishlistStore(queue: try DatabaseQueue(path: path))
    let changes = try await reopened.changes(for: [row.id], now: now)
    #expect(changes.filter { !$0.isRead }.count == 1)
    #expect(changes.first?.label == "提前上线")
    #expect(try await reopened.count(mode: .changes, sources: [.youku], now: now, unreadOnly: true) == 1)
    #expect(try await reopened.works(mode: .changes, sources: [.youku], now: now, unreadOnly: true).count == 1)
    try await reopened.markRead(changeIDs: changes.map(\.id))
    try await store.replace([row], source: .youku, at: now.addingTimeInterval(2))
    #expect(try await reopened.count(mode: .changes, sources: [.youku], now: now, unreadOnly: true) == 0)
    #expect(try await reopened.count(mode: .changes, sources: [.youku], now: now) == 1)
    #expect(try await reopened.works(mode: .changes, sources: [.youku], now: now, unreadOnly: true).isEmpty)
    try await reopened.setWanted(helper.work([row]), wanted: false)
    try await queue.run { db in
      let stmt = try db.prepare("SELECT COUNT(*) FROM upcoming_change_reads")
      defer { sqlite3_finalize(stmt) }
      _ = sqlite3_step(stmt)
      #expect(db.int(stmt, 0) == 0)
    }
  }

  @Test func unreadBatchesRemainReachableAndSourceFilteringDoesNotMarkThem() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var row = helper.release()
    let now = helper.now
    try await store.replace([row], source: .youku, at: now)
    try await wants.setWanted(helper.work([row]), wanted: true, at: now)
    for index in 1...12 {
      row.releaseTime = index.isMultiple(of: 2) ? "10:00" : "16:00"
      try await store.replace([row], source: .youku, at: now.addingTimeInterval(Double(index)))
    }
    #expect(try await wants.count(mode: .changes, sources: [.iqiyi], now: now, unreadOnly: true) == 0)
    let first = try await wants.changes(for: [row.id], now: now)
    #expect(first.count == 10)
    try await wants.markRead(changeIDs: first.map(\.id))
    #expect(try await wants.hasUnread(for: [row.id], now: now))
    let second = try await wants.changes(for: [row.id], now: now)
    #expect(second.filter { !$0.isRead }.count == 2)
    try await wants.markRead(changeIDs: second.map(\.id))
    #expect(try await !wants.hasUnread(for: [row.id], now: now))
    #expect(try await wants.count(mode: .changes, sources: [.youku], now: now.addingTimeInterval(91 * 86400)) == 0)
  }

  @Test func watchlistEntriesRequireTrustedPriorBatchAndFollowTime() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    let helper = LocalChartTests()
    let store = LocalChartStore(queue: queue)
    let now = helper.date("2026-10-29T05:00:00Z")
    try await helper.batch(repo, [1, 2, 3], .recent, "2026-10-28T01:00:00Z")
    try await repo.addToWatchlist(videoID: 1, at: helper.date("2026-10-28T02:00:00Z"))
    #expect(try await store.watchlistEntries(now: now).isEmpty)
    try await helper.batch(repo, [2, 3, 4], .recent, "2026-10-29T01:00:00Z")
    try await helper.batch(repo, [1, 3, 4], .recent, "2026-10-29T02:00:00Z")
    try await helper.batch(repo, [1, 3, 4], .recent, "2026-10-29T03:00:00Z")
    let entries = try await store.watchlistEntries(now: now)
    #expect(entries.count == 1)
    #expect(entries[0].videoID == 1 && entries[0].scope == .recent)
    #expect(entries[0].observedAt == helper.date("2026-10-29T02:00:00Z"))
    // 另一榜首次出现及碎片基线都不制造新事件。
    try await helper.batch(repo, [1, 3, 4], .weekly, "2026-10-29T02:00:00Z")
    try await helper.batch(repo, [2], .monthly, "2026-10-29T01:00:00Z")
    try await helper.batch(repo, [1, 3, 4], .monthly, "2026-10-29T02:00:00Z")
    #expect(try await store.watchlistEntries(now: now).count == 1)
    #expect(try await store.watchlistEntries(now: now.addingTimeInterval(3 * 86400)).isEmpty)
    try await repo.removeFromWatchlist(videoID: 1)
    try await repo.addToWatchlist(videoID: 1, at: now)
    #expect(try await store.watchlistEntries(now: now).isEmpty)
  }
}
