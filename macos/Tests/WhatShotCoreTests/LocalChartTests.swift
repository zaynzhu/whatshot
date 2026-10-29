import Foundation
import Testing
@testable import WhatShotCore

struct LocalChartTests {
  func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

  func batch(_ repo: VideoRepository, _ ids: [Int], _ scope: ButaiChartScope = .recent, _ time: String) async throws {
    let helper = WhatsNewTests()
    _ = try await repo.upsertBatch(ids.enumerated().map {
      (helper.makeVideo(id: $0.element, kind: .movie), $0.offset + 1)
    }, chartScope: scope, observedAt: date(time))
  }

  @Test func preservesThreeIndependentRanksAndUsesOnlyLatestMembership() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    try await batch(repo, [4, 1, 2], .recent, "2026-10-28T02:00:00Z")
    try await batch(repo, [1, 2, 3], .recent, "2026-10-29T02:00:00Z")
    try await batch(repo, [2, 1, 3], .weekly, "2026-10-29T02:01:00Z")
    try await batch(repo, [3, 2, 1], .monthly, "2026-10-29T02:02:00Z")
    let rows = try await LocalChartStore(queue: queue).signals(now: date("2026-10-29T03:00:00Z"))
    #expect(rows[4] == nil)
    #expect(rows[1]?.map(\.rank) == [1, 2, 3])
    #expect(rows[1]?.map(\.scope) == [.recent, .weekly, .monthly])
    #expect(rows[1]?.map(\.consecutiveDays) == [2, 1, 1])
  }

  @Test func sameDayDoesNotInflateStreakAndShanghaiMidnightCounts() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    try await batch(repo, [1, 2], .recent, "2026-10-28T14:30:00Z")
    try await batch(repo, [2, 1], .recent, "2026-10-28T15:30:00Z")
    let store = LocalChartStore(queue: queue)
    #expect(try await store.signals(now: date("2026-10-28T15:35:00Z"))[1]?.first?.consecutiveDays == 1)
    try await batch(repo, [1, 2], .recent, "2026-10-28T16:30:00Z")
    #expect(try await store.signals(now: date("2026-10-28T16:35:00Z"))[1]?.first?.consecutiveDays == 2)
  }

  @Test func missingDayOrObservedExitBreaksStreak() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    try await batch(repo, [1, 2], .recent, "2026-10-26T02:00:00Z")
    try await batch(repo, [1, 2], .recent, "2026-10-28T02:00:00Z")
    let store = LocalChartStore(queue: queue)
    #expect(try await store.signals(now: date("2026-10-28T03:00:00Z"))[1]?.first?.consecutiveDays == 1)
    try await batch(repo, [2, 3], .recent, "2026-10-28T04:00:00Z")
    try await batch(repo, [1, 2], .recent, "2026-10-29T02:00:00Z")
    let result = try await store.signals(now: date("2026-10-29T03:00:00Z"))
    #expect(result[1]?.first?.consecutiveDays == 1)
    #expect(result[2]?.first?.consecutiveDays == 2)
  }

  @Test func truncatedOldBatchDoesNotProveContinuousPresence() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    try await batch(repo, [1], .recent, "2026-10-28T02:00:00Z")
    try await batch(repo, [1, 2, 3], .recent, "2026-10-29T02:00:00Z")
    #expect(try await LocalChartStore(queue: queue).signals(now: date("2026-10-29T03:00:00Z"))[1]?.first?.consecutiveDays == 1)
  }

  @Test func sharedRequiresFreshLocalAndTrueExternalHeat() async throws {
    let now = date("2026-10-29T03:00:00Z")
    let local = [LocalChartSignal(scope: .recent, rank: 3, observedAt: now)]
    let queue = try DatabaseQueue(path: ":memory:")
    let store = ExternalHeatStore(queue: queue)
    var signal = WhatsNewTests().makeSignal(id: "s", mediaItemId: "m", rank: 3)
    signal.capturedAt = "2026-10-29T02:00:00Z"
    _ = try await store.upsertSignals([.init(signal: signal, mediaTitle: "作品", mediaType: "movie",
      posterURL: nil, firstReleaseDate: nil, match: nil)], fetchedAt: now)
    var external = try #require(try await store.displayRows().first)
    #expect(WorkHeatTier.resolve(local: [], external: [], now: now) == .none)
    #expect(WorkHeatTier.resolve(local: local, external: [], now: now) == .local)
    #expect(WorkHeatTier.resolve(local: [], external: [external], now: now) == .external)
    #expect(WorkHeatTier.resolve(local: local, external: [external], now: now) == .shared)
    let stale = [LocalChartSignal(scope: .recent, rank: 3, observedAt: now.addingTimeInterval(-49 * 3600))]
    #expect(WorkHeatTier.resolve(local: stale, external: [external], now: now) == .external)
    for source in ["iqiyi_reserve", "imdb_rating", "douban_top", "douban_upcoming", "unknown"] {
      external.source = source
      #expect(WorkHeatTier.resolve(local: local, external: [external], now: now) == .local)
    }
    external.source = signal.source
    external.isCurrent = false
    #expect(WorkHeatTier.resolve(local: local, external: [external], now: now) == .local)
  }
}
