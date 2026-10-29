import Foundation
import Testing
@testable import WhatShotCore

struct WorkHeatFilterTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-29T03:00:00Z")!

  @Test func filtersBeforePaginationAndCountsBeyondFirstPage() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    let helper = VideoRepositoryTests()
    let items = (1...130).map { id -> (video: ButaiVideo, rank: Int?) in
      var video = helper.makeVideo(id: id)
      video.seedUpdatedAt = String(format: "2026-10-29 00:%02d:%02d", id / 60, id % 60)
      return (video, nil)
    }
    _ = try await repo.upsertBatch(items, chartScope: nil, observedAt: now)
    #expect(try await repo.countVideos(kind: .tvSeries) == 130)
    let ids = Set(1...70)
    let first = try await repo.listVideos(kind: .tvSeries, limit: 60, offset: 0, matchingIDs: ids)
    let second = try await repo.listVideos(kind: .tvSeries, limit: 60, offset: 60, matchingIDs: ids)
    #expect(first.count == 60)
    #expect(second.count == 10)
    #expect(Set((first + second).map(\.id)) == ids)
    #expect(first.first?.id == 70)
    #expect(second.last?.id == 1)
    #expect(try await repo.countVideos(kind: .tvSeries, matchingIDs: ids) == 70)
    #expect(try await repo.listVideos(kind: .tvSeries, limit: 60, offset: 0, matchingIDs: [1]).map(\.id) == [1])
    #expect(try await repo.listVideos(kind: .tvSeries, limit: 60, offset: 0, matchingIDs: []).isEmpty)
    #expect(try await repo.countVideos(kind: .tvSeries, matchingIDs: []) == 0)
  }

  @Test func countsAndRowsShareSearchCategoryAndIdentityIntersection() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    for id in 1...4 {
      var video = VideoRepositoryTests().makeVideo(id: id)
      video.alias = "共同_别名"
      if id == 2 { video.productionArea = "美国" }
      if id == 3 { video.kind = .movie }
      _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    }
    let filter = VideoRepository.ListFilter(years: "2026", airing: .ongoing, classNames: "剧情", area: "日本")
    let rows = try await repo.listVideos(kind: .tvSeries, limit: 60, offset: 0,
      filter: filter, query: "共同_", matchingIDs: [1, 2, 3])
    #expect(rows.map(\.id) == [1])
    #expect(try await repo.countVideos(kind: .tvSeries, filter: filter, query: "共同_", matchingIDs: [1, 2, 3]) == 1)
    #expect(try await repo.countVideos(kind: .tvSeries, query: "共同%") == 0)
    #expect(try await repo.countVideos(kind: .movie, query: "共同_", matchingIDs: [1, 2, 3]) == 1)
  }

  @Test func membershipUsesExactFreshHeatAndHonorsExternalDisable() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    let helper = WhatsNewTests()
    _ = try await repo.upsertBatch((1...3).map { (helper.makeVideo(id: $0, kind: .movie), nil) },
      chartScope: nil, observedAt: now)
    var signal = helper.makeSignal(id: "s", mediaItemId: "m", rank: 3)
    signal.capturedAt = "2026-10-29T02:00:00Z"
    let store = ExternalHeatStore(queue: queue)
    _ = try await store.upsertSignals([.init(signal: signal, mediaTitle: "作品", mediaType: "movie",
      posterURL: nil, firstReleaseDate: nil, match: .init(videoID: 1, basis: .imdb))], fetchedAt: now)
    let row = try #require(try await store.displayRows().first)
    var reserve = row
    reserve.source = "iqiyi_reserve"
    reserve.video = try await repo.video(id: 2)
    var stale = row
    stale.video = try await repo.video(id: 3)
    stale.fetchedAt = now.addingTimeInterval(-49 * 3600)
    var unlinked = row
    unlinked.video = nil
    let local = [
      1: [LocalChartSignal(scope: .recent, rank: 2, observedAt: now)],
      2: [LocalChartSignal(scope: .weekly, rank: 4, observedAt: now)],
      3: [LocalChartSignal(scope: .recent, rank: 1, observedAt: now.addingTimeInterval(-49 * 3600))]
    ]
    let external = [row, row, reserve, stale, unlinked]
    let membership = WorkHeatMembership(local: local, external: external, externalEnabled: true, now: now)
    #expect(membership.ids(for: .all) == nil)
    #expect(membership.ids(for: .local) == [1, 2])
    #expect(membership.ids(for: .external) == [1])
    #expect(membership.ids(for: .shared) == [1])
    let disabled = WorkHeatMembership(local: local, external: external, externalEnabled: false, now: now)
    #expect(disabled.ids(for: .local) == [1, 2])
    #expect(disabled.ids(for: .external) == [])
    #expect(disabled.ids(for: .shared) == [])
  }
}
