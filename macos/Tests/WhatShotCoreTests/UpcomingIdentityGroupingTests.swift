import Foundation
import Testing
@testable import WhatShotCore

struct UpcomingIdentityGroupingTests {
  let helper = UpcomingGroupingTests()
  var now: Date { helper.now }

  func cache(_ rows: [UpcomingRelease], id: String, imdb: String? = nil, tmdb: Int? = nil,
             videoID: Int? = nil, queue: DatabaseQueue) async throws {
    var refs = rows.map { WhatsNewClient.MediaDetail.SourceRef(source: $0.source.rawValue, sourceId: "\($0.source.rawValue)-\($0.sourceID)") }
    if let tmdb { refs.append(.init(source: "tmdb", sourceId: "tmdb-movie-\(tmdb)")) }
    let signal = WhatsNewTests().makeSignal(id: "signal-\(id)", mediaItemId: id, mediaType: rows[0].kind)
    _ = try await ExternalHeatStore(queue: queue).upsertSignals([
      .init(signal: signal, mediaTitle: rows[0].title, mediaType: rows[0].kind, posterURL: nil,
        firstReleaseDate: nil, match: videoID.map { .init(videoID: $0, basis: .imdb) })
    ], fetchedAt: now, details: [.init(id: id, imdbId: imdb, sourceRefs: refs)])
  }

  @Test func verifiedAliasesMergeBeforeWindowsAndKeepOriginalSchedules() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let a = helper.row(.youku, "a", "电影：副标题", date: "2026-10-30", time: "16:00")
    let b = helper.row(.tencent, "b", "电影:副标题", date: "2026-11-01")
    let c = helper.row(.iqiyi, "c", "电影")
    for row in [a, b, c] { try await store.replace([row], source: row.source, at: now) }
    try await cache([a, b, c], id: "movie", imdb: "tt123", tmdb: 9, queue: queue)
    let works = try await store.works(sources: UpcomingSource.allCases, externalEnabled: true, now: now)
    #expect(works.count == 1)
    let merged = try #require(works.first)
    #expect(merged.releases == [a, c, b])
    #expect(merged.releaseDate == "2026-10-30")
    #expect(try await store.works(sources: UpcomingSource.allCases, window: .undated, externalEnabled: true, now: now).isEmpty)
    let later = try await store.works(sources: UpcomingSource.allCases, window: .recent,
      externalEnabled: true, now: now.addingTimeInterval(6 * 86400))
    #expect(later.first?.releaseDate == "2026-11-01")
    #expect(later.first?.id == merged.id)
    #expect(try await store.works(sources: UpcomingSource.allCases, externalEnabled: false, now: now).count == 2)
    #expect(try await store.works(sources: [.iqiyi], window: .undated, externalEnabled: true, now: now).first?.releases == [c])
  }

  @Test func aliasPaginationHasSixtyWorksNotSixtyPlatformEntries() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let a = (0..<65).map { helper.row(.youku, "y\($0)", "电影\($0)") }
    let b = (0..<65).map { helper.row(.tencent, "t\($0)", "电影\($0)：副标题") }
    try await store.replace(a, source: .youku, at: now)
    try await store.replace(b, source: .tencent, at: now)
    for index in a.indices { try await cache([a[index], b[index]], id: "m\(index)", queue: queue) }
    let first = try await store.works(sources: [.youku, .tencent], window: .undated, externalEnabled: true, now: now)
    let second = try await store.works(sources: [.tencent, .youku], window: .undated, externalEnabled: true, now: now, offset: 60)
    #expect(first.count == 60)
    #expect(second.count == 5)
    #expect((first + second).allSatisfy { $0.releases.count == 2 })
    #expect(Set((first + second).flatMap(\.releases).map(\.id)).count == 130)
    #expect(Set((first + second).map(\.id)).count == 65)
  }

  @Test func sharedIdentityDoesNotCrossRegionReleaseTypeOrSeason() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let a = helper.row(.youku, "a", "电影")
    var b = helper.row(.tencent, "b", "电影：副标题")
    b.region = "US"
    var c = helper.row(.iqiyi, "c", "电影：另一个名字")
    c.releaseType = "digital"
    for row in [a, b, c] { try await store.replace([row], source: row.source, at: now) }
    try await cache([a, b, c], id: "movie", imdb: "tt111", queue: queue)
    #expect(try await store.works(sources: UpcomingSource.allCases, window: .undated, externalEnabled: true, now: now).count == 3)
    let season1 = helper.row(.youku, "s1", "剧集 第一季", kind: "series")
    let season2 = helper.row(.iqiyi, "s2", "剧集 第二季", kind: "series")
    try await store.replace([a, season1], source: .youku, at: now)
    try await store.replace([c, season2], source: .iqiyi, at: now)
    try await cache([season1, season2], id: "series", imdb: "tt222", queue: queue)
    #expect(try await store.works(sources: UpcomingSource.allCases, kind: "series", window: .undated, externalEnabled: true, now: now).count == 2)
  }

  @Test func conflictingIdentityCannotMergeThroughTitleOrTransitiveBridge() throws {
    let a = helper.row(.youku, "a", "同名电影")
    let b = helper.row(.iqiyi, "b", "同名电影")
    let c = helper.row(.tencent, "c", "另一个片名")
    var left = WorkConnection()
    left.verifiedIDs = ["imdb": "tt111", "tmdb": "1"]
    var middle = WorkConnection()
    middle.verifiedIDs = ["tmdb": "1"]
    var right = WorkConnection()
    right.verifiedIDs = ["imdb": "tt222", "tmdb": "1"]
    let links = [a.id: left, b.id: middle, c.id: right]
    let keys = try UpcomingGrouping.keys(rows: [a, b, c], connections: links)
    #expect(Set(keys.values).count == 3)
    #expect(try UpcomingGrouping.keys(rows: [c, b, a], connections: links) == keys)
    #expect(try UpcomingGrouping.keys(rows: [a, b], connections: [a.id: left]).values.count == 2)
    #expect(Set(try UpcomingGrouping.keys(rows: [a, b], connections: [a.id: left]).values).count == 2)
  }

  @Test func duplicateSourceIDsSplitWholeCandidateEvenWithVerifiedIdentity() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let store = UpcomingStore(queue: queue)
    let a = helper.row(.youku, "a", "电影")
    let b = helper.row(.youku, "b", "电影：别名")
    let c = helper.row(.iqiyi, "c", "电影：副标题")
    try await store.replace([a, b], source: .youku, at: now)
    try await store.replace([c], source: .iqiyi, at: now)
    try await cache([a, b, c], id: "movie", imdb: "tt111", queue: queue)
    let works = try await store.works(sources: [.youku, .iqiyi], window: .undated, externalEnabled: true, now: now)
    #expect(works.count == 3)
    #expect(works.allSatisfy { $0.releases.count == 1 })
  }

  @Test func conflictingExternalAndLibraryIDsAreNotUsableEvidence() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let repo = VideoRepository(queue: queue)
    _ = try await repo.upsertBatch([(WhatsNewTests().makeVideo(id: 1, kind: .movie, imdb: "tt111"), nil)], chartScope: nil, observedAt: now)
    let a = helper.row(.youku, "a", "同名")
    let b = helper.row(.iqiyi, "b", "同名")
    let store = UpcomingStore(queue: queue)
    try await store.replace([a], source: .youku, at: now)
    try await store.replace([b], source: .iqiyi, at: now)
    try await cache([a], id: "wrong", imdb: "tt222", videoID: 1, queue: queue)
    try await cache([b], id: "right", imdb: "tt111", videoID: 1, queue: queue)
    #expect(try await WorkConnectionStore(queue: queue).connections(for: [a], externalEnabled: true)[a.id] == nil)
    #expect(try await store.works(sources: [.youku, .iqiyi], window: .undated, externalEnabled: true, now: now).count == 2)
  }

  @Test func localizationFingerprintAndConflictingSourceReferencesAreChecked() async throws {
    let queue = try DatabaseQueue(path: ":memory:")
    let links = WorkConnectionStore(queue: queue)
    let row = WorkConnectionTests().release(.whenToStream)
    try await links.saveLocalization(.init(tmdbID: 9, imdbID: "tt111", chineseTitle: "中文名"), for: row, at: now)
    #expect(try await links.connections(for: [row], externalEnabled: false)[row.id]?.verifiedIDs == ["tmdb": "9", "imdb": "tt111"])
    var changed = row
    changed.productionYear = 1990
    #expect(try await links.connections(for: [changed], externalEnabled: false)[row.id]?.verifiedIDs.isEmpty == true)
    try await cache([row], id: "conflict", imdb: "tt222", queue: queue)
    #expect(try await links.connections(for: [row], externalEnabled: true)[row.id] == nil)
    #expect(try await links.connections(for: [row], externalEnabled: false)[row.id]?.verifiedIDs["tmdb"] == "9")
  }

  @Test func matchingImdbTmdbOrLibraryIdentityWorksWithoutMatchingTitle() throws {
    let a = helper.row(.youku, "a", "电影")
    let b = helper.row(.tencent, "b", "电影：副标题")
    for namespace in ["imdb", "tmdb", "video", "media"] {
      var connection = WorkConnection()
      connection.verifiedIDs = [namespace: "123"]
      let keys = try UpcomingGrouping.keys(rows: [a, b], connections: [a.id: connection, b.id: connection])
      #expect(keys[a.id] == keys[b.id])
    }
    #expect(Set(try UpcomingGrouping.keys(rows: [a, b], connections: [a.id: .empty, b.id: .empty]).values).count == 2)
  }
}
