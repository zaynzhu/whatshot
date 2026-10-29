import Foundation
import Testing
@testable import WhatShotCore

struct UpcomingWishlistTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-29T04:00:00Z")!
  func release(_ source: UpcomingSource = .youku, id: String = "one", date: String? = "2026-10-30") -> UpcomingRelease {
    UpcomingRelease(source: source, sourceID: id, kind: "movie", title: "测试影片",
      sourceURL: "https://example.com", region: source.region, releaseDate: date,
      rawSchedule: date ?? "待定档", observedAt: now)
  }
  func work(_ rows: [UpcomingRelease]) -> UpcomingWork { .init(id: "display", releaseDate: rows.first?.releaseDate, releases: rows) }

  @Test func followsSourceIdentityAndRecordsOnlyActualChanges() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    var a = release()
    try await store.replace([a], source: .youku, at: now)
    try await wants.setWanted(work([a]), wanted: true, at: now)
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(1))
    #expect(try await wants.changes(for: [a.id], now: now).isEmpty)
    a.title = "改名仍是同一作品"
    a.releaseTime = "16:00"
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(2))
    var changes = try await wants.changes(for: [a.id], now: now)
    #expect(changes.count == 1)
    #expect(changes[0].reason == "公布时刻")
    #expect(changes[0].after?.title == a.title)
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(3))
    #expect(try await wants.changes(for: [a.id], now: now).count == 1)
    a.releaseDate = nil
    a.releaseTime = nil
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(4))
    changes = try await wants.changes(for: [a.id], now: now)
    #expect(changes.first?.reason == "撤回日期")
    let rows = try await wants.works(mode: .wanted, sources: [.youku], now: now)
    #expect(rows.count == 1)
    #expect(rows[0].releaseDate == nil)
    #expect(rows[0].title == a.title)
    #expect(try await wants.works(mode: .changes, sources: [.youku], now: now).count == 1)
    #expect(try await wants.works(mode: .wanted, sources: [], now: now).isEmpty)
    #expect(try await wants.savedIDs() == [a.id])
  }

  @Test func removalRestoreFailureAndCancellationPreserveTruth() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    let a = release()
    let other = release(id: "other")
    try await store.replace([a], source: .youku, at: now)
    try await wants.setWanted(work([a]), wanted: true, at: now)
    try await store.recordFailure(.youku, message: "网络失败", at: now)
    #expect(try await wants.changes(for: [a.id], now: now).isEmpty)
    // 在快照写入阶段强制失败，关注状态与变动必须跟着整批回滚。
    try await queue.run { db in
      try db.exec("CREATE TRIGGER fail_upcoming BEFORE INSERT ON upcoming_releases BEGIN SELECT RAISE(ABORT,'test'); END")
    }
    do {
      try await store.replace([other], source: .youku, at: now.addingTimeInterval(1))
      Issue.record("应回滚失败快照")
    } catch {}
    #expect(try await wants.inactiveIDs(for: [a.id]).isEmpty)
    #expect(try await wants.changes(for: [a.id], now: now).isEmpty)
    try await queue.run { try $0.exec("DROP TRIGGER fail_upcoming") }
    try await store.replace([other], source: .youku, at: now.addingTimeInterval(2))
    #expect(try await wants.inactiveIDs(for: [a.id]) == [a.id])
    #expect(try await wants.works(mode: .wanted, sources: [.youku], now: now).count == 1)
    #expect(try await wants.works(mode: .week, sources: [.youku], now: now).isEmpty)
    try await store.replace([other], source: .youku, at: now.addingTimeInterval(3))
    #expect(try await wants.changes(for: [a.id], now: now).count == 1)
    try await store.replace([a], source: .youku, at: now.addingTimeInterval(4))
    #expect(try await wants.changes(for: [a.id], now: now).first?.reason == "恢复片单")
    #expect(try await wants.inactiveIDs(for: [a.id]).isEmpty)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.replace([other], source: .youku, at: now.addingTimeInterval(5))
    }
    do { try await cancelled.value; Issue.record("取消的批次不应提交") } catch {}
    #expect(try await wants.inactiveIDs(for: [a.id]).isEmpty)
    #expect(try await wants.changes(for: [a.id], now: now).count == 2)
    // 30 天片单清理也不能删收藏。
    try await store.replace([other], source: .youku, at: now.addingTimeInterval(5))
    try await store.replace([other], source: .youku, at: now.addingTimeInterval(40 * 86400))
    #expect(try await wants.savedIDs() == [a.id])
  }

  @Test func groupsPersistAcrossReopenAndWeekUsesRegionalCalendar() async throws {
    let path = NSTemporaryDirectory() + "wishlist-\(UUID()).sqlite3"
    defer {
      for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    let queue = try DatabaseQueue(path: path)
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    let a = release()
    let b = release(.tencent, date: "2026-11-03")
    let us = release(.whenToStream, date: "2026-11-01")
    try await store.replace([a], source: .youku, at: now)
    try await store.replace([b], source: .tencent, at: now)
    try await store.replace([us], source: .whenToStream, at: now)
    try await wants.setWanted(work([a, b]), wanted: true, at: now)
    try await wants.setWanted(work([us]), wanted: true, at: now)
    let reopened = UpcomingWishlistStore(queue: try DatabaseQueue(path: path))
    #expect(try await reopened.savedIDs().count == 3)
    let week = try await reopened.works(mode: .week, sources: [.youku, .tencent], now: now)
    #expect(week.count == 1)
    #expect(week[0].releases.count == 2)
    let boundary = ISO8601DateFormatter().date(from: "2026-11-02T01:00:00Z")!
    #expect(UpcomingWishlistStore.weekBounds(at: boundary, region: "CN").start == "2026-11-02")
    #expect(UpcomingWishlistStore.weekBounds(at: boundary, region: "US").start == "2026-10-26")
    #expect(try await reopened.works(mode: .week, sources: [.whenToStream], now: boundary).count == 1)
    #expect(try await reopened.works(mode: .week, sources: [.youku], now: boundary).isEmpty)
    try await reopened.setWanted(work([a]), wanted: false)
    #expect(try await reopened.savedIDs() == [b.id, us.id])
  }

  @Test func paginationCountsSavedWorksNotPlatformRows() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let wants = UpcomingWishlistStore(queue: queue)
    let rows = (1...65).map { release(id: "\($0)") }
    try await store.replace(rows, source: .youku, at: now)
    for row in rows { try await wants.setWanted(work([row]), wanted: true, at: now) }
    let first = try await wants.works(mode: .wanted, sources: [.youku], now: now)
    let second = try await wants.works(mode: .wanted, sources: [.youku], now: now, offset: 60)
    #expect(first.count == 60)
    #expect(second.count == 5)
    #expect(Set((first + second).map(\.id)).count == 65)
  }
}
