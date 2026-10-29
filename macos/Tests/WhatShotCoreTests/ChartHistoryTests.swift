import Foundation
import SQLite3
import Testing
@testable import WhatShotCore

struct ChartHistoryTests {
  let helper = LocalChartTests()

  @Test func localHistoryKeepsGapsAndLastDailyRankSeparateByScope() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    try await helper.batch(repo, [1, 2], .recent, "2026-10-26T15:00:00Z")
    try await helper.batch(repo, [2, 1], .recent, "2026-10-26T15:30:00Z")
    try await helper.batch(repo, [1, 2], .weekly, "2026-10-26T15:30:00Z")
    // 北京日期已到 27 日，完整快照中没有作品 1。
    try await helper.batch(repo, [2, 3], .recent, "2026-10-26T16:10:00Z")
    try await helper.batch(repo, [1], .recent, "2026-10-29T02:00:00Z")
    let rows = try await ChartHistoryStore(queue: queue).history(videoID: 1, externalEnabled: false,
      now: helper.date("2026-10-29T03:00:00Z"))
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.days.count == 14 })
    #expect(rows[0].days.first { $0.day == "2026-10-26" }?.rank == 2)
    #expect(rows[1].days.first { $0.day == "2026-10-26" }?.rank == 1)
    let absent = try #require(rows[0].days.first { $0.day == "2026-10-27" })
    #expect(absent.sampled && absent.rank == nil)
    #expect(rows[0].days.first { $0.day == "2026-10-28" }?.sampled == false)
    #expect(rows[0].days.last?.rank == 1)
  }

  @Test func externalHistoryDeduplicatesCaptureAndDoesNotFillMissingDates() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    let make = WhatsNewTests()
    _ = try await repo.upsertBatch([(make.makeVideo(id: 1, kind: .movie), nil)], chartScope: nil,
      observedAt: helper.date("2026-10-27T03:00:00Z"))
    let store = ExternalHeatStore(queue: queue)
    var signal = make.makeSignal(id: "s", mediaItemId: "m", rank: 8)
    for (day, rank, entry) in [("27", 8, "season1"), ("27", 8, "season1"), ("29", 2, "season1"), ("29", 4, "season2")] {
      signal.capturedAt = "2026-10-\(day)T02:00:00Z"
      signal.rank = rank
      signal.rankingEntryKey = entry
      _ = try await store.upsertSignals([.init(signal: signal, mediaTitle: "作品", mediaType: "movie",
        posterURL: nil, firstReleaseDate: nil, match: .init(videoID: 1, basis: .imdb))],
        fetchedAt: helper.date("2026-10-\(day)T03:00:00Z"))
    }
    let history = ChartHistoryStore(queue: queue)
    let now = helper.date("2026-10-29T04:00:00Z")
    let rows = try await history.history(videoID: 1, externalEnabled: true, now: now).filter(\.external)
    #expect(rows.count == 2)
    #expect(rows.flatMap(\.days).compactMap(\.rank).sorted() == [2, 4, 8])
    #expect(rows.allSatisfy { $0.days.first { $0.day == "2026-10-28" }?.sampled == false })
    #expect(try await history.history(videoID: 1, externalEnabled: false, now: now).count == 3)
    let count = try await queue.run { db in
      let stmt = try db.prepare("SELECT COUNT(*) FROM external_chart_history")
      defer { sqlite3_finalize(stmt) }
      sqlite3_step(stmt)
      return db.int(stmt, 0)
    }
    #expect(count == 3)
  }
}
