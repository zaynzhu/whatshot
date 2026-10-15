import Foundation
import Testing
import SQLite3
@testable import WhatShotCore

struct MovieReleaseDateTests {
  private let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!

  private func makeRepo() throws -> VideoRepository {
    VideoRepository(queue: try DatabaseQueue(path: ":memory:"))
  }

  private func movie(_ id: Int, release: String?, year: String? = "2026") -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: 30000000 + id, title: "目标电影\(id)", originalTitle: nil, alias: nil,
      episodeStatus: "", episodes: "0", definition: nil, years: year,
      classNames: "剧情", productionArea: "日本", doubanScore: nil, imdbNumber: nil, imdbScore: nil,
      posterURL: nil, seedCount: 0, netdiskCount: 0,
      seedUpdatedAt: String(format: "2026-10-%02d", id), updatedAt: nil,
      director: nil, performer: nil, abstract: nil, release: release, kind: .movie
    )
  }

  @Test func parsesCommercialReleaseIndependentlyFromTV() {
    let cases: [(String?, String?)] = [
      ("2025-08-29(威尼斯电影节), 2026-08-07(美国)", "2026-08-07"),
      ("2026-05-22(中国大陆), 2026-04-19(北京国际电影节)", "2026-05-22"),
      ("2026-05-12(戛纳电影节,法国)", nil),
      ("2026-01-01(美国, 中国大陆)", "2026-01-01"),
      ("2026-01-02（中国大陆网络）, 2026-01-01(美国网络)", "2026-01-01"),
      ("2026-01-01(首映), 2026-01-02(点映), 2026-01-03(重映)", nil),
      ("2026-01-01(Film Festival), 2026-01-02(PREMIERE)", nil),
      ("2026-01-01(平遥国际电影展), 2026-01-02(影展), 2026-01-03(电影周)", nil),
      ("2026-01-01", nil), ("2026-01-01( )", nil),
      ("2026(未定), 2025-06(电影节)", nil), ("2026-02-30(美国)", nil),
      ("2026-02-29(美国)", nil), ("2024-02-29(美国)", "2024-02-29"),
      ("2026-13-01(美国), 2026-00-01(美国), 2026-01-00(美国)", nil),
      ("12026-01-01(美国), 2026-01-011(美国), 2026-2-03(美国)", nil),
      ("0999-01-01(美国)", nil), ("2027-01-01(美国)", "2027-01-01"),
      (nil, nil), ("", nil)
    ]
    for (raw, expected) in cases { #expect(MovieReleaseDate.parse(raw) == expected) }
    let tv = Data(#"{"pubdate":["2026-04-19(北京国际电影节)","2026-05-22(中国大陆)"]}"#.utf8)
    #expect(DoubanClient.parsePremiereDate(from: tv) == "2026-04-19")
  }

  @Test func upsertPreservesMissingAndRecomputesCorrections() async throws {
    let repo = try makeRepo()
    let raw = "2025-08-29(电影节), 2026-08-07(美国)"
    _ = try await repo.upsert(movie(1, release: raw), chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.video(id: 1)?.premiereDate == "2026-08-07")
    #expect(try await repo.video(id: 1)?.premiereSource == "butai0")
    for missing: String? in [nil, "", " \n\t "] {
      _ = try await repo.upsert(movie(1, release: missing), chartScope: nil, chartRank: nil, now: now)
      #expect(try await repo.video(id: 1)?.releaseInfo == raw)
      #expect(try await repo.video(id: 1)?.premiereDate == "2026-08-07")
    }
    _ = try await repo.upsert(movie(1, release: "2026-09-01(美国)"), chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.video(id: 1)?.premiereDate == "2026-09-01")
    _ = try await repo.upsert(movie(1, release: "2026-09-01(电影节)"), chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.video(id: 1)?.premiereDate == nil)
    #expect(try await repo.video(id: 1)?.premiereSource == nil)
  }

  @Test func preservesForeignDatesAndUsesVideoIdentity() async throws {
    let repo = try makeRepo()
    var first = movie(1, release: "2026-01-01(美国)")
    var second = movie(2, release: "2026-02-01(美国)")
    second.doubanId = first.doubanId
    _ = try await repo.upsertBatch([(first, nil), (second, nil)], chartScope: nil, observedAt: now)
    #expect(try await repo.video(id: 1)?.premiereDate == "2026-01-01")
    #expect(try await repo.video(id: 2)?.premiereDate == "2026-02-01")
    try await repo.queue.run { db in
      try db.exec("UPDATE videos SET premiere_date='2024-01-01', premiere_source='douban' WHERE id=1")
      try db.exec("UPDATE videos SET premiere_date='2023-01-01', premiere_source=NULL WHERE id=2")
    }
    first.release = "2026-03-01(美国)"
    _ = try await repo.upsert(first, chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.normalizeMovieReleaseDates(at: now) == 0)
    #expect(try await repo.video(id: 1)?.premiereDate == "2024-01-01")
    #expect(try await repo.video(id: 2)?.premiereDate == "2023-01-01")
  }

  @Test func kindUpgradeClearsOnlyMovieDerivedDate() async throws {
    let repo = try makeRepo()
    var video = movie(1, release: "2026-01-01(美国)")
    _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    video.kind = .tvSeries
    _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.video(id: 1)?.premiereDate == nil)
    let stamp = try await repo.queue.run { db in
      let statement = try db.prepare("SELECT premiere_fetched_at FROM videos WHERE id=1")
      defer { sqlite3_finalize(statement) }
      _ = sqlite3_step(statement)
      return db.int(statement, 0)
    }
    #expect(stamp == nil)
    try await repo.setPremiereDate(doubanId: 30000001, date: "2025-12-01", at: now)
    video.kind = .movie
    _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    #expect(try await repo.video(id: 1)?.kind == .tvSeries)
    #expect(try await repo.video(id: 1)?.premiereDate == "2025-12-01")
  }

  @Test func backfillIsAtomicAcrossPagesAndIdempotent() async throws {
    let repo = try makeRepo()
    let items = (1...205).map { (video: movie($0, release: "2026-01-01(美国)"), rank: Int?.none) }
    _ = try await repo.upsertBatch(items, chartScope: nil, observedAt: now)
    try await repo.queue.run { db in
      try db.exec("UPDATE videos SET premiere_date=NULL, premiere_source=NULL, premiere_fetched_at=NULL")
      try db.exec("CREATE TRIGGER reject_movie_date BEFORE UPDATE OF premiere_date ON videos WHEN NEW.id=202 BEGIN SELECT RAISE(ABORT, 'simulated'); END")
    }
    await #expect(throws: (any Error).self) { try await repo.normalizeMovieReleaseDates(at: now) }
    #expect(try await repo.video(id: 1)?.premiereDate == nil)
    #expect(try await repo.video(id: 201)?.premiereDate == nil)
    try await repo.queue.run { db in try db.exec("DROP TRIGGER reject_movie_date") }
    #expect(try await repo.normalizeMovieReleaseDates(at: now) == 205)
    #expect(try await repo.normalizeMovieReleaseDates(at: now.addingTimeInterval(60)) == 0)
    #expect(try await repo.video(id: 205)?.premiereDate == "2026-01-01")
  }

  @Test func failedNormalizationRollsBackEntireUpsertBatch() async throws {
    let repo = try makeRepo()
    try await repo.queue.run { db in
      try db.exec("CREATE TRIGGER reject_movie_date BEFORE UPDATE OF premiere_date ON videos WHEN NEW.id=2 BEGIN SELECT RAISE(ABORT, 'simulated'); END")
    }
    await #expect(throws: (any Error).self) {
      try await repo.upsertBatch([(movie(1, release: "2026-01-01(美国)"), 1), (movie(2, release: "2026-01-02(美国)"), 2)], chartScope: .weekly, observedAt: now)
    }
    #expect(try await repo.video(id: 1) == nil)
    #expect(try await repo.latestChart(.weekly).isEmpty)
  }

  @Test func mixedPrecisionSortingAndFilters() async throws {
    let repo = try makeRepo()
    let fixtures: [(Int, String?, String?)] = [
      (1, "2025", "2026-08-07(美国)"), (2, "2026", "2026-09-01(美国)"),
      (3, "2026", nil), (4, "1998", "1998-09-01(美国)"),
      (5, "2025", "2026-11-01(美国)"), (6, "2027", nil), (7, "未知", nil),
      (8, "2026", "2026-02-30(美国)"), (9, "2025", "2026-09-01(美国)"),
      (10, nil, "2026-07-01(美国)")
    ]
    for (id, year, release) in fixtures {
      _ = try await repo.upsert(movie(id, release: release, year: year), chartScope: nil, chartRank: nil, now: now)
    }
    let ordered = try await repo.listVideos(kind: .movie, limit: 20, offset: 0, sort: .newestYear, now: now)
    #expect(ordered.map(\.id) == [9, 2, 1, 10, 8, 3, 4, 7, 6, 5])
    let page = try await repo.listVideos(kind: .movie, limit: 3, offset: 3, sort: .newestYear, now: now)
    #expect(page.map(\.id) == [10, 8, 3])
    let filtered = try await repo.listVideos(kind: .movie, limit: 20, offset: 0, sort: .newestYear,
      filter: .init(years: "2025", classNames: "剧情", area: "日本"), query: "目标", now: now)
    #expect(filtered.map(\.id) == [9, 1, 5])
    let resourceOrder = try await repo.listVideos(kind: .movie, limit: 20, offset: 0, sort: .seedUpdated, now: now)
    #expect(resourceOrder.map(\.id) == Array((1...10).reversed()))
  }
}
