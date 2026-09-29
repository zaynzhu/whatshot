import Foundation
import SQLite3
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

  /// 多地区数组：取最早完整日期（新口径：不分地区；美 08-20 早于陆 08-31）
  @Test func parsePicksEarliestAmongMultiple() {
    #expect(parse(["2026-08-20(美国)", "2026-08-31(中国大陆)"]) == "2026-08-20")
  }

  /// 非大陆地区：照收（定案"全都要"，不分地区）
  @Test func parseAcceptsForeignRegion() {
    #expect(parse(["2026-09-10(韩国)"]) == "2026-09-10")
    #expect(parse(["2001-09-27(美国)"]) == "2001-09-27")
  }

  /// 多地区多日期：取最早 = 真实首播（数组顺序不影响结果）
  @Test func parsePicksEarliestAcrossRegions() {
    #expect(parse(["2026-09-10(韩国)", "2026-09-01(中国大陆)"]) == "2026-09-01")
    #expect(parse(["2026-08-20(中国大陆)", "2026-09-10(韩国)"]) == "2026-08-20")
  }

  /// 仅年份仍然不补假日期
  @Test func parseRejectsYearOnly() {
    #expect(parse(["2025(中国大陆)"]) == nil)
    #expect(parse(["2025(美国)"]) == nil)
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

  /// 重查规则：无日期条目 24h 内不重查；过期后重查（豆瓣可能后来补上）；有日期永不重查
  @Test func premiereCandidatesRecheck() async throws {
    let repo = try makeRepo()
    let now = Date()
    for i in 1...3 {
      _ = try await repo.upsert(makeVideo(id: i), chartScope: nil, chartRank: nil, now: now)
    }
    let all = try await repo.premiereCandidates(limit: 10, now: now)
    #expect(all.count == 3)

    // 1 号拿到日期；2 号无日期；3 号无日期但刚抓过（1 小时前）
    try await repo.setPremiereDate(doubanId: all[0], date: "2026-09-01", at: now)
    try await repo.setPremiereDate(doubanId: all[1], date: nil, at: now)
    try await repo.setPremiereDate(doubanId: all[2], date: nil, at: now.addingTimeInterval(-3600))

    let hourLater = now.addingTimeInterval(7200)
    let fresh = try await repo.premiereCandidates(limit: 10, now: hourLater)
    #expect(!fresh.contains(all[0]))        // 有日期：不重查
    #expect(!fresh.contains(all[1]))        // 无日期但刚抓过：不重查
    #expect(!fresh.contains(all[2]))        // 3 小时前抓的：仍不重查
    #expect(try await repo.premierePendingCount(now: hourLater) == 0)

    // 25 小时后：两个无日期条目到期重查
    let dayLater = now.addingTimeInterval(25 * 3600)
    let due = try await repo.premiereCandidates(limit: 10, now: dayLater)
    #expect(due.contains(all[1]) && due.contains(all[2]))
    #expect(!due.contains(all[0]))
    #expect(try await repo.premierePendingCount(now: dayLater) == 2)
  }

  // MARK: - 补全引擎 403 条目级/风控级区分（2026-09-29：《史莱姆》38232831 连续 12 轮稳定 403
  // 而同轮其余 60 条全 200，IP 未被封——旧规则"403 即停批"让单条目把补全队列堵死）

  /// 按 URL 末段 douban_id 无状态分发（经验库：避免 stub static 状态并行交叉污染）。
  /// 37000001/37000005→403、37000002→200 有日期、37000003→200 仅年份（no_date）、37000004→401
  final class PremiereStubURLProtocol: URLProtocol {
    static func makeSession() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [PremiereStubURLProtocol.self]
      return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url, let id = url.path.split(separator: "/").last else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let status: Int
      let json: String
      switch id {
      case "37000001", "37000005":
        status = 403; json = #"{"code":403,"msg":"resource_access_denied"}"#
      case "37000002":
        status = 200; json = #"{"title":"x","pubdate":["2026-09-01(日本)"]}"#
      case "37000003":
        status = 200; json = #"{"title":"x","pubdate":["2025(日本)"]}"#
      case "37000004":
        status = 401; json = #"{"code":401}"#
      default:
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        return
      }
      guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(json.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  /// makeVideo 的 seedUpdatedAt 按 id 尾数递增，候选顺序为 id 倒序（seed_updated_at DESC）
  func makePremiereEngine(repo: VideoRepository) -> (SyncEngine, DoubanClient) {
    let douban = DoubanClient(limiter: RateLimiter(interval: 0), session: PremiereStubURLProtocol.makeSession())
    let engine = SyncEngine(client: ButaiClient(baseURL: "https://www.butai0.club", limiter: RateLimiter(interval: 0), session: PremiereStubURLProtocol.makeSession()),
                            repo: repo, settings: ButaiSettings(baseURL: "https://www.butai0.club", syncIntervalHours: 6, posterCacheLimitMB: 300, movieListPages: 1, tvListPages: 1),
                            douban: douban)
    return (engine, douban)
  }

  func makeRepoWithQueue() throws -> (VideoRepository, DatabaseQueue) {
    let tmp = NSTemporaryDirectory() + "whatshot-premiere-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return (VideoRepository(queue: queue), queue)
  }

  func doubanObservations(queue: DatabaseQueue) async throws -> [(Int, Int?, String)] {
    try await queue.run { db in
      let stmt = try db.prepare("SELECT douban_id, http_status, outcome FROM douban_requests ORDER BY id")
      defer { sqlite3_finalize(stmt) }
      var rows: [(Int, Int?, String)] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let id = db.int(stmt, 0) ?? 0
        let status = db.int(stmt, 1)
        let outcome = db.text(stmt, 2) ?? ""
        rows.append((id, status, outcome))
      }
      return rows
    }
  }

  func premiereFetchedAt(doubanId: Int, queue: DatabaseQueue) async throws -> Int? {
    try await queue.run { db in
      let stmt = try db.prepare("SELECT premiere_fetched_at FROM videos WHERE douban_id = ?")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, doubanId)
      guard sqlite3_step(stmt) == SQLITE_ROW,
            sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
      return db.int(stmt, 0)
    }
  }

  /// 批内首次 403 = 条目级：该条 24h 退避出队、本批继续、不产 warning（"部分完成"消失的关键）
  @Test func backfillFirst403DefersAndContinues() async throws {
    let (repo, queue) = try makeRepoWithQueue()
    let now = Date()
    for i in 1...3 {
      _ = try await repo.upsert(makeVideo(id: i), chartScope: nil, chartRank: nil, now: now)
    }
    // 候选顺序 [3, 2, 1]：3 no_date、2 got_date、1 条目级 403
    let (engine, douban) = makePremiereEngine(repo: repo)
    let summary = await engine.backfillPremieres(douban: douban, runId: 0)

    #expect(summary.warning == nil)          // 条目级跳过不产 warning
    #expect(summary.withDate == 1)           // 只有 2 号拿到日期
    #expect(summary.fetched == 3)

    // 403 条目：日期仍空但 fetched_at 置位（24h 退避，与 no_date 同口径）
    #expect(try await premiereFetchedAt(doubanId: 370_000_01, queue: queue) != nil)
    let hoursLater = now.addingTimeInterval(2 * 3600)
    let fresh = try await repo.premiereCandidates(limit: 10, now: hoursLater)
    #expect(!fresh.contains(370_000_01))     // 403 退避中不出队
    #expect(!fresh.contains(370_000_03))     // no_date 正常退避
    let dayLater = now.addingTimeInterval(25 * 3600)
    #expect(try await repo.premiereCandidates(limit: 10, now: dayLater).contains(370_000_01))  // 到期重查

    // 观测表如实记录：3 条请求，1 号 blocked 403
    let obs = try await doubanObservations(queue: queue)
    #expect(obs.count == 3)
    #expect(obs.contains { $0.0 == 370_000_01 && $0.1 == 403 && $0.2 == "blocked" })
  }

  /// 批内第 2 次 403（另一条目同样被拒）= IP 级风控：立即停批；下轮钉子户已退避、批自愈
  @Test func backfillSecond403StopsThenSelfHeals() async throws {
    let (repo, queue) = try makeRepoWithQueue()
    let now = Date()
    for i in [1, 2, 3, 5] {
      _ = try await repo.upsert(makeVideo(id: i), chartScope: nil, chartRank: nil, now: now)
    }
    // 首轮候选 [5, 3, 2, 1]：5 首次 403（条目级退避续批）→ 3 no_date → 2 got_date
    // → 1 第二次 403（另一条目也被拒）→ 判风控停批
    let (engine, douban) = makePremiereEngine(repo: repo)
    let first = await engine.backfillPremieres(douban: douban, runId: 0)
    #expect(first.warning?.contains("本批补全中止") == true)
    #expect(first.withDate == 1)                                     // 2 号在停批前已补上
    #expect(try await doubanObservations(queue: queue).count == 4)   // 5/3/2/1 各一条

    // 5 号已退避出队；1 号（停批分支）未退避，下轮仍是队头
    // 第二轮候选 [1]：1 首次 403 → 退避续批 → 批自愈（不再产 warning）
    let second = await engine.backfillPremieres(douban: douban, runId: 0)
    #expect(second.warning == nil)
    #expect(second.withDate == 0)
    #expect(try await doubanObservations(queue: queue).count == 5)
    #expect(try await premiereFetchedAt(doubanId: 370_000_01, queue: queue) != nil)  // 次轮退避

    // 第三轮：两个钉子户都在退避期、无其他待补 → 零请求空转
    let third = await engine.backfillPremieres(douban: douban, runId: 0)
    #expect(third.warning == nil)
    #expect(third.fetched == 0)
  }

  /// 401 非 403：维持现行"立即停批"，不走条目级退避
  @Test func backfill401StillStopsImmediately() async throws {
    let (repo, queue) = try makeRepoWithQueue()
    let now = Date()
    for i in 3...4 {
      _ = try await repo.upsert(makeVideo(id: i), chartScope: nil, chartRank: nil, now: now)
    }
    // 候选 [4, 3]：4 → 401 立即停批，3 未请求
    let (engine, douban) = makePremiereEngine(repo: repo)
    let summary = await engine.backfillPremieres(douban: douban, runId: 0)
    #expect(summary.warning?.contains("HTTP 401") == true)
    #expect(summary.withDate == 0)
    let obs = try await doubanObservations(queue: queue)
    #expect(obs.count == 1)
    #expect(obs[0].0 == 370_000_04 && obs[0].1 == 401)
    // 401 不退避：条目保持出队资格（下轮照常重试）
    #expect(try await premiereFetchedAt(doubanId: 370_000_04, queue: queue) == nil)
  }

  /// markPremiereBlocked 只置 fetched_at，不碰已有日期与来源（防将来误改实现清掉豆瓣好值）
  @Test func markPremiereBlockedPreservesDate() async throws {
    let (repo, queue) = try makeRepoWithQueue()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 5), chartScope: nil, chartRank: nil, now: now)
    try await repo.setPremiereDate(doubanId: 370_000_05, date: "2026-01-01", at: now)
    try await repo.markPremiereBlocked(doubanId: 370_000_05, at: now.addingTimeInterval(60))

    try await queue.run { db in
      let stmt = try db.prepare("SELECT premiere_date, premiere_source FROM videos WHERE douban_id = ?")
      defer { sqlite3_finalize(stmt) }
      SQLiteDatabase.bind(stmt, 1, 370_000_05)
      #expect(sqlite3_step(stmt) == SQLITE_ROW)
      #expect(db.text(stmt, 0) == "2026-01-01")
      #expect(db.text(stmt, 1) == "douban")
    }
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
    let airing = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(airing: .ongoing))
    #expect(airing.map(\.id) == [1])
    // 类型多值 LIKE（"剧情,犯罪" 命中单选"犯罪"）
    let crime = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(classNames: "犯罪"))
    #expect(crime.map(\.id) == [1])
    // 地区 LIKE（"中国大陆" 命中"大陆"）
    let mainland = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(area: "大陆"))
    #expect(mainland.map(\.id) == [1])
    // 组合：2026 + 播出中
    let combined = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, filter: .init(years: "2026", airing: .ongoing))
    #expect(combined.map(\.id) == [1])
    // 筛选 + 首播排序叠加
    try await repo.setPremiereDate(doubanId: 370_000_02, date: "1999-09-21", at: now)
    let filteredSorted = try await repo.listVideos(kind: .tvSeries, limit: 10, offset: 0, sort: .premiere, filter: .init(years: "90年代"))
    #expect(filteredSorted.first?.premiereDate == "1999-09-21")
  }
}