import Foundation
import Testing
@testable import WhatShotCore

/// 豆瓣 pubdate 解析与首播日补全、排序、筛选测试（2026-09-13 定案）
struct PremiereTests {
  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-premiere-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
  }

  func makeVideo(id: Int, years: String = "2026", ejs: String = "更新至9集",
                 classNames: String? = "剧情", area: String? = "中国大陆") -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: 370_000_00 + id, title: "剧集\(id)", originalTitle: nil, alias: nil,
      episodeStatus: ejs, episodes: "12", definition: nil, years: years,
      classNames: classNames, productionArea: area, doubanScore: nil, imdbNumber: nil, imdbScore: nil,
      posterURL: nil, seedCount: 10, netdiskCount: 0, seedUpdatedAt: "2026-09-13 10:00:0\(id % 10)",
      updatedAt: nil, director: nil, performer: nil, abstract: nil,
      release: nil, kind: .tvSeries
    )
  }

  // MARK: - pubdate 解析（定案：只取完整 YYYY-MM-DD 且标注中国大陆）

  private func parse(_ pubdates: [String]) -> String? {
    let data = try! JSONSerialization.data(withJSONObject: ["pubdate": pubdates])
    return DoubanClient.parsePremiereDate(from: data)
  }

  /// 实测样例：飞到我心上 ["2026-08-31(中国大陆)"] → 2026-08-31
  @Test func parseFullDateWithMainlandRegion() {
    #expect(parse(["2026-08-31(中国大陆)"]) == "2026-08-31")
  }

  /// 多地区数组：优先命中中国大陆条目
  @Test func parsePicksMainlandAmongMultiple() {
    #expect(parse(["2026-08-20(美国)", "2026-08-31(中国大陆)"]) == "2026-08-31")
  }

  /// 仅年份不补假日期（不得补成 1-1）
  @Test func parseRejectsYearOnly() {
    #expect(parse(["2025(中国大陆)"]) == nil)
  }

  /// 无地区标记的完整日期不取（可能任意地区）
  @Test func parseRejectsDateWithoutRegion() {
    #expect(parse(["2026-08-31"]) == nil)
  }

  /// 非大陆地区不取
  @Test func parseRejectsForeignRegion() {
    #expect(parse(["2001-09-27(美国)"]) == nil)
  }

  /// 缺字段/坏 JSON 容错返回 nil
  @Test func parseToleratesMissingOrMalformed() {
    let bad = "not json".data(using: .utf8)!
    #expect(DoubanClient.parsePremiereDate(from: bad) == nil)
    let noField = try! JSONSerialization.data(withJSONObject: ["title": "x"])
    #expect(DoubanClient.parsePremiereDate(from: noField) == nil)
    #expect(parse([]) == nil)
  }

  // MARK: - 年代档位映射（对齐 butai0 字典 t3）

  @Test func yearRangeMapping() {
    let calendar = Calendar(identifier: .gregorian)
    let y2026 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13))!
    #expect(VideoRepository.yearRange(for: "近三年", now: y2026)?.low == 2024)
    #expect(VideoRepository.yearRange(for: "近三年", now: y2026)?.high == 2026)
    #expect(VideoRepository.yearRange(for: "2026", now: y2026)?.low == 2026)
    #expect(VideoRepository.yearRange(for: "2026", now: y2026)?.high == 2026)
    #expect(VideoRepository.yearRange(for: "2025", now: y2026)?.low == 2025)
    #expect(VideoRepository.yearRange(for: "90年代", now: y2026)?.low == 1990)
    #expect(VideoRepository.yearRange(for: "90年代", now: y2026)?.high == 1999)
    #expect(VideoRepository.yearRange(for: "20年代", now: y2026)?.low == 2020)
    #expect(VideoRepository.yearRange(for: "20年代", now: y2026)?.high == 2029)
    #expect(VideoRepository.yearRange(for: "10年代", now: y2026)?.low == 2010)
    #expect(VideoRepository.yearRange(for: "00年代", now: y2026)?.low == 2000)
    #expect(VideoRepository.yearRange(for: "80年代", now: y2026)?.low == 1980)
    #expect(VideoRepository.yearRange(for: "更早", now: y2026)?.high == 1979)
    #expect(VideoRepository.yearRange(for: "乱码", now: y2026) == nil)
  }

  // MARK: - 首播日写入与排序（定案 Q6/Q7/Q8：倒序、未知置尾、未来照排）

  @Test func premiereSortOrder() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 3), chartScope: nil, chartRank: nil, now: now)
    // 1=今天首播，2=昨天，3=无日期；2 的资源更新最新（验证未知条目不被资源时间顶上去）
    try await repo.setPremiereDate(doubanId: 370_000_01, date: "2026-09-13", at: now)
    try await repo.setPremiereDate(doubanId: 370_000_02, date: "2026-09-12", at: now)

    let rows = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .premiere)
    #expect(rows.map(\.id) == [1, 2, 3])         // 首播倒序，未知排尾
    #expect(rows[0].premiereDate == "2026-09-13")
    #expect(rows[2].premiereDate == nil)

    // 未来日期照排最前（Q8：豆瓣日期可信，不特判）
    _ = try await repo.upsert(makeVideo(id: 4), chartScope: nil, chartRank: nil, now: now)
    try await repo.setPremiereDate(doubanId: 370_000_04, date: "2030-01-01", at: now)
    let futureFirst = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .premiere)
    #expect(futureFirst.first?.id == 4)
  }

  /// 集数更新/资源重供不改变首播排序位置（用户核心诉求）
  @Test func seedUpdateDoesNotReorder() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, years: "2001"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2), chartScope: nil, chartRank: nil, now: now)
    try await repo.setPremiereDate(doubanId: 370_000_01, date: "2001-09-27", at: now)
    try await repo.setPremiereDate(doubanId: 370_000_02, date: "2026-09-10", at: now)

    // 老剧（老友记场景）资源刚被重供：seed_updated 最新
    let revived = makeVideo(id: 1, years: "2001")
    let revivedVideo = ButaiVideo(
      id: 1, doubanId: 370_000_01, title: "剧集1", originalTitle: nil, alias: nil,
      episodeStatus: "全集", episodes: "24", definition: nil, years: "2001",
      classNames: "喜剧", productionArea: "美国", doubanScore: nil, imdbNumber: nil, imdbScore: nil,
      posterURL: nil, seedCount: 99, netdiskCount: 0, seedUpdatedAt: "2026-09-13 23:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil, kind: .tvSeries
    )
    _ = revived
    _ = try await repo.upsert(revivedVideo, chartScope: nil, chartRank: nil, now: now)

    let rows = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .premiere)
    #expect(rows.map(\.id) == [2, 1])            // 2026 新剧在前，重供老剧仍沉底
    // 资源更新排序下老剧仍冒头（该排序保留给找资源场景）
    let bySeed = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .seedUpdated)
    #expect(bySeed.first?.id == 1)
  }

  // MARK: - 补全候选与三档限速输入（定案四）

  @Test func premiereCandidatesSkipFetched() async throws {
    let repo = try makeRepo()
    let now = Date()
    for i in 1...3 {
      _ = try await repo.upsert(makeVideo(id: i), chartScope: nil, chartRank: nil, now: now)
    }
    let pendingBefore = try await repo.premierePendingCount()
    #expect(pendingBefore == 3)
    let candidates = try await repo.premiereCandidates(limit: 10)
    #expect(candidates.count == 3)

    // 无日期也置位 fetched_at：不反复重查已知无日期条目
    try await repo.setPremiereDate(doubanId: candidates[0], date: nil, at: now)
    let pendingAfter = try await repo.premierePendingCount()
    #expect(pendingAfter == 2)
    let next = try await repo.premiereCandidates(limit: 10)
    #expect(!next.contains(candidates[0]))
  }

  // MARK: - 筛选（定案一：年代/状态/类型/地区，纯本地 WHERE）

  @Test func listFilters() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, years: "2026", ejs: "更新至9集", classNames: "剧情,犯罪", area: "中国大陆"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, years: "1999", ejs: "全集", classNames: "喜剧", area: "美国"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 3, years: "2026", ejs: "全集", classNames: "动画", area: "日本"), chartScope: nil, chartRank: nil, now: now)

    // 年代 2026
    let y2026 = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(years: "2026"))
    #expect(y2026.map(\.id).sorted() == [1, 3])
    // 90年代
    let old = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(years: "90年代"))
    #expect(old.map(\.id) == [2])
    // 播出中
    let airing = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(airingOnly: true))
    #expect(airing.map(\.id) == [1])
    // 类型多值 LIKE（"剧情,犯罪" 命中单选"犯罪"）
    let crime = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(classNames: "犯罪"))
    #expect(crime.map(\.id) == [1])
    // 地区 LIKE（"中国大陆" 命中"大陆"）
    let mainland = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(area: "大陆"))
    #expect(mainland.map(\.id) == [1])
    // 组合：2026 + 播出中
    let combined = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(years: "2026", airingOnly: true))
    #expect(combined.map(\.id) == [1])
    // 筛选 + 首播排序叠加
    try await repo.setPremiereDate(doubanId: 370_000_02, date: "1999-09-21", at: now)
    let filteredSorted = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .premiere, filter: .init(years: "90年代"))
    #expect(filteredSorted.first?.premiereDate == "1999-09-21")
  }
}