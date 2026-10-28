import Foundation
import Testing
@testable import WhatShotCore

struct WorkConnectionTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-28T08:00:00Z")!

  func release(_ source: UpcomingSource = .youku, id: String = "show1") -> UpcomingRelease {
    UpcomingRelease(source: source, sourceID: id, kind: "movie", title: "Same Name (2026)",
      sourceURL: "https://example.com/film", region: source.region, rawSchedule: "待定档", observedAt: now,
      originalTitle: "Same Name", productionYear: 2026, directors: ["Jane Doe"])
  }

  @Test func exactSourceIdentityLinksAndDisabledSourceHidesConnection() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    let helper = WhatsNewTests()
    _ = try await repo.upsertBatch([(helper.makeVideo(id: 7, kind: .movie, imdb: "tt123"), nil)], chartScope: nil, observedAt: now)
    let store = ExternalHeatStore(queue: queue)
    let signal = helper.makeSignal(id: "s1", mediaItemId: "m1", mediaType: "movie")
    _ = try await store.upsertSignals([.init(signal: signal, mediaTitle: "中文作品", mediaType: "movie", posterURL: nil,
      firstReleaseDate: nil, match: .init(videoID: 7, basis: .imdb))], fetchedAt: now,
      details: [.init(id: "m1", imdbId: "tt123", sourceRefs: [.init(source: "youku", sourceId: "youku-show1")])])
    let links = WorkConnectionStore(queue: queue)
    let row = release()
    #expect(try await links.connections(for: [row], externalEnabled: true)[row.id]?.videoID == 7)
    #expect(try await links.connections(for: [row], externalEnabled: false)[row.id]?.videoID == nil)
    var wrongKind = row
    wrongKind.kind = "series"
    #expect(try await links.connections(for: [wrongKind], externalEnabled: true)[wrongKind.id]?.mediaID == nil)
    let sameTitle = release(id: "other")
    #expect(try await links.connections(for: [sameTitle], externalEnabled: true)[sameTitle.id]?.videoID == nil)
    try await UpcomingStore(queue: queue).replace([row], source: .youku, at: now)
    #expect(try await links.releases(forVideo: 7, sources: [.youku], externalEnabled: true).count == 1)
    #expect(try await links.releases(forVideo: 7, sources: [], externalEnabled: true).isEmpty)
  }

  @Test func conflictingReferencesAndLocalizedIdentityNeverGuess() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let helper = WhatsNewTests()
    let store = ExternalHeatStore(queue: queue)
    for id in ["one", "two"] {
      _ = try await store.upsertSignals([.init(signal: helper.makeSignal(id: id, mediaItemId: id, mediaType: "movie"),
        mediaTitle: "同名", mediaType: "movie", posterURL: nil, firstReleaseDate: nil, match: nil)], fetchedAt: now,
        details: [.init(id: id, imdbId: nil, sourceRefs: [.init(source: "youku", sourceId: "youku-show1")])])
    }
    let links = WorkConnectionStore(queue: queue)
    let row = release()
    #expect(try await links.connections(for: [row], externalEnabled: true)[row.id] == nil)
    let foreign = release(.whenToStream)
    try await links.saveLocalization(.init(tmdbID: 99, imdbID: "tt123", chineseTitle: "中文片名"), for: foreign, at: now)
    #expect(try await links.connections(for: [foreign], externalEnabled: false)[foreign.id]?.chineseTitle == "中文片名")
    var changed = foreign
    changed.directors = ["Different Director"]
    #expect(try await links.connections(for: [changed], externalEnabled: false)[changed.id]?.chineseTitle == nil)
    #expect(WorkConnection.combined([.init(videoID: 1), .init(videoID: 2)]) == .empty)
    #expect(WorkConnection.combined([.init(mediaID: "a"), .init(mediaID: "b")]) == .empty)
  }

  @Test func freshnessAndRankChangesHaveDistinctSemantics() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = ExternalHeatStore(queue: queue)
    var signal = WhatsNewTests().makeSignal(id: "signal", mediaItemId: "media", rank: 3)
    signal.capturedAt = "2026-10-28T07:00:00Z"
    signal.previousRank = 6
    signal.rankDelta = 3
    _ = try await store.upsertSignals([.init(signal: signal, mediaTitle: "测试", mediaType: "movie", posterURL: nil,
      firstReleaseDate: nil, match: nil)], fetchedAt: now)
    var row = try #require(try await store.displayRows().first)
    #expect(ExternalSignalPresentation.hasHeat([row], now: now))
    #expect(ExternalSignalPresentation.rise(row, now: now) == 3)
    row.previousRank = nil
    #expect(ExternalSignalPresentation.rise(row, now: now) == nil)
    row.previousRank = 10
    #expect(ExternalSignalPresentation.rise(row, now: now) == nil)
    for source in ["imdb_rating", "douban_top", "douban_upcoming", "youku_reserve", "iqiyi_reserve", "apple_tv_plus_news", "unknown"] {
      row.source = source
      #expect(!ExternalSignalPresentation.hasHeat([row], now: now))
    }
    row.source = "trakt_trending"
    #expect(!ExternalSignalPresentation.hasHeat([row], now: now.addingTimeInterval(49 * 3600)))
    row.capturedAt = nil
    #expect(!ExternalSignalPresentation.hasHeat([row], now: now))
    row.capturedAt = "2026-10-30T08:00:00Z"
    #expect(!ExternalSignalPresentation.hasHeat([row], now: now))
    row.capturedAt = "2026-10-28T07:00:00Z"
    row.isCurrent = false
    #expect(!ExternalSignalPresentation.hasHeat([row], now: now))
  }
}
