import Foundation
import Testing
@testable import WhatShotCore

/// 我的追剧与更新汇总测试（2026-09-20 定案七）：关注 CRUD、检查候选最旧优先、
/// 更新汇总水位口径（关注前历史不报、首尾比较不重复、回退如实、无基线不报）
struct WatchlistTests {
  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-watch-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
  }

  func makeVideo(id: Int, ejs: String = "更新至9集", alias: String? = nil,
                 doubanId: Int? = nil) -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: doubanId, title: "测试剧集\(id)", originalTitle: nil, alias: alias,
      episodeStatus: ejs, episodes: "24", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "日本", doubanScore: nil, imdbNumber: nil, imdbScore: nil,
      posterURL: nil, seedCount: 10, netdiskCount: 0, seedUpdatedAt: "2026-09-20 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil, kind: .tvSeries
    )
  }

  // MARK: - CRUD

  @Test func watchlistCrudIdempotent() async throws {
    let repo = try makeRepo()
    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let t2 = t1.addingTimeInterval(3600)
    _ = try await repo.upsert(makeVideo(id: 1), chartScope: nil, chartRank: nil, now: t1)

    try await repo.addToWatchlist(videoID: 1, at: t1)
    #expect(try await repo.isWatched(videoID: 1))

    // 重复关注幂等：created_at（水位起点）不被前移
    try await repo.addToWatchlist(videoID: 1, at: t2)
    let rows = try await repo.watchlistRows()
    #expect(rows.count == 1)
    #expect(rows[0].createdAt == t1)
    #expect(rows[0].video.id == 1)

    try await repo.removeFromWatchlist(videoID: 1)
    #expect(try await repo.isWatched(videoID: 1) == false)
    #expect(try await repo.watchlistRows().isEmpty)
  }

  // MARK: - 检查候选

  /// 最久未检查优先（NULL last_detail_at 最先）；无豆瓣 ID 的条目检查不了，排除
  @Test func detailCandidatesOldestFirst() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, doubanId: 101), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, doubanId: 102), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 3, doubanId: 103), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 4, doubanId: nil), chartScope: nil, chartRank: nil, now: now)
    try await repo.addToWatchlist(videoID: 1, at: now)
    try await repo.addToWatchlist(videoID: 2, at: now)
    try await repo.addToWatchlist(videoID: 3, at: now)
    try await repo.addToWatchlist(videoID: 4, at: now)
    // 2 检查过（较新），1 从未检查，3 检查得更早
    try await repo.markDetailSynced(videoID: 2, at: now.addingTimeInterval(1000))
    try await repo.markDetailSynced(videoID: 3, at: now.addingTimeInterval(100))

    let candidates = try await repo.watchlistDetailCandidates(limit: 10)
    #expect(candidates.map(\.videoID) == [1, 3, 2]) // 4 无豆瓣 ID 排除；1(NULL) → 3(最旧) → 2
  }

  // MARK: - 更新汇总口径

  @Test func updatesSinceWatermark() async throws {
    let repo = try makeRepo()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    // 关注前两条观察（9集），关注后推进到 10、12 集
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至9集", doubanId: 101), chartScope: nil, chartRank: nil, now: t0)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至9集", doubanId: 101), chartScope: nil, chartRank: nil, now: t0.addingTimeInterval(60))
    let watchAt = t0.addingTimeInterval(120)
    try await repo.addToWatchlist(videoID: 1, at: watchAt)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至10集", doubanId: 101), chartScope: nil, chartRank: nil, now: watchAt.addingTimeInterval(60))
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至12集", doubanId: 101), chartScope: nil, chartRank: nil, now: watchAt.addingTimeInterval(120))

    // 水位早于关注时刻：报 9集 → 12集（首尾比较，关注前历史与中间态不进结果）
    let updates = try await repo.watchlistUpdates(since: t0)
    #expect(updates.count == 1)
    #expect(updates[0].fromEjs == "更新至9集")
    #expect(updates[0].toEjs == "更新至12集")
    #expect(updates[0].observedAt == watchAt.addingTimeInterval(120))

    // 水位推进到最后一次观察之后：不再报（已读）
    let again = try await repo.watchlistUpdates(since: watchAt.addingTimeInterval(121))
    #expect(again.isEmpty)
  }

  /// 集数回退（站方修正）如实展示方向：12 → 7
  @Test func updatesReportRollbackAsIs() async throws {
    let repo = try makeRepo()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至12集", doubanId: 101), chartScope: nil, chartRank: nil, now: t0)
    let watchAt = t0.addingTimeInterval(60)
    try await repo.addToWatchlist(videoID: 1, at: watchAt)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至7集", doubanId: 101), chartScope: nil, chartRank: nil, now: watchAt.addingTimeInterval(60))

    let updates = try await repo.watchlistUpdates(since: watchAt)
    #expect(updates.count == 1)
    #expect(updates[0].fromEjs == "更新至12集")
    #expect(updates[0].toEjs == "更新至7集")
  }

  /// 无基线不报：关注后才有第一条观察（关注前无任何观察）不算变化；
  /// 已完结（全集）作为 to 如实上报
  @Test func updatesRequireBaselineAndReportEnded() async throws {
    let repo = try makeRepo()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    // 条目 1：关注时库内还没有观察 → 第一条观察不构成变化
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "", doubanId: 101), chartScope: nil, chartRank: nil, now: t0.addingTimeInterval(10))
    try await repo.addToWatchlist(videoID: 1, at: t0)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至5集", doubanId: 101), chartScope: nil, chartRank: nil, now: t0.addingTimeInterval(60))
    #expect(try await repo.watchlistUpdates(since: t0).isEmpty)

    // 条目 2：关注前有 9集基线，关注后完结
    _ = try await repo.upsert(makeVideo(id: 2, ejs: "更新至9集", doubanId: 102), chartScope: nil, chartRank: nil, now: t0)
    try await repo.addToWatchlist(videoID: 2, at: t0.addingTimeInterval(30))
    _ = try await repo.upsert(makeVideo(id: 2, ejs: "全集12集", doubanId: 102), chartScope: nil, chartRank: nil, now: t0.addingTimeInterval(90))
    let updates = try await repo.watchlistUpdates(since: t0)
    #expect(updates.count == 1)
    #expect(updates[0].video.id == 2)
    #expect(updates[0].toEjs == "全集12集")
  }

  // MARK: - 本地搜索（listVideos query）

  @Test func listVideosSearchQuery() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, alias: "黑色四叶草"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2), chartScope: nil, chartRank: nil, now: now)

    // 别名命中（定案七验收）
    let byAlias = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: "四叶草")
    #expect(byAlias.map(\.id) == [1])
    // 片名命中
    let byTitle = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: "测试剧集2")
    #expect(byTitle.map(\.id) == [2])
    // 空查询与空白 = 不筛
    #expect(try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: nil).count == 2)
    #expect(try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: "   ").count == 2)
    // 无匹配
    #expect(try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: "不存在的名字").isEmpty)
    // LIKE 通配符按字面匹配："%"" 不当通配符
    let literal = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, query: "%")
    #expect(literal.isEmpty)
  }
}
