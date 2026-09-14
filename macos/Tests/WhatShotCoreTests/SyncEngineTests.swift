import Foundation
import Testing
@testable import WhatShotCore

/// 同步引擎测试：榜单批次观察时间戳、写库失败不被静默吞掉。
/// latestChart 按 MAX(observed_at) 单秒切片，逐条各取时间跨秒写入会缺榜
/// （详见 docs/whatsnew-reuse-assessment.md 4.1 的合成验证）
struct SyncEngineTests {
  /// 每次调用前进一秒的时钟：生产逐条 Date() 跨秒不可控，注入后可确定性复现
  final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Date
    private var tick = 0
    init(base: Date) { self.base = base }
    func next() -> Date {
      lock.lock()
      defer { lock.unlock() }
      tick += 1
      return base.addingTimeInterval(TimeInterval(tick))
    }
  }

  /// butai0 接口 stub：榜单回 3 条（不带 doub_id/idcode，豆瓣 ID 为 nil → 不触发详情补拉），
  /// 列表回空。其余路径一律失败，防止测试误打真实网络
  final class ButaiStubURLProtocol: URLProtocol {
    static let chartJSON = """
    {"success":true,"code":200,"data":{"data":[
      {"id":1,"title":"甲","ejs":"更新至1集","tp":2,"episodes":"12","seed_num":5,"wp_num":1},
      {"id":2,"title":"乙","ejs":"更新至2集","tp":2,"episodes":"12","seed_num":6,"wp_num":1},
      {"id":3,"title":"丙","ejs":"更新至3集","tp":2,"episodes":"12","seed_num":7,"wp_num":1}
    ]}}
    """
    static let emptyListJSON = """
    {"success":true,"code":200,"data":{"page":1,"limit":25,"total":0,"list":[]}}
    """

    static func makeSession() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ButaiStubURLProtocol.self]
      return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let json: String
      if url.path.contains("getVideoList") {
        json = Self.chartJSON
      } else if url.path.contains("getVideoMovieList") {
        json = Self.emptyListJSON
      } else {
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        return
      }
      guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(json.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  func makeEngine(queue: DatabaseQueue) -> SyncEngine {
    let repo = VideoRepository(queue: queue)
    let client = ButaiClient(
      baseURL: "https://www.butai0.club",
      limiter: RateLimiter(interval: 0),
      session: ButaiStubURLProtocol.makeSession()
    )
    let settings = ButaiSettings(
      baseURL: "https://www.butai0.club",
      syncIntervalHours: 6, posterCacheLimitMB: 300,
      movieListPages: 1, tvListPages: 1
    )
    return SyncEngine(client: client, repo: repo, settings: settings)
  }

  /// 回归：同一榜单批次必须共享一个观察时间戳——逐条各取时间跨秒写入时，
  /// latestChart 只剩最大秒那一行，榜单缺条（本测试复现评估文档 4.1 的合成验证）
  @Test func chartBatchSharesOneTimestamp() async throws {
    let tmp = NSTemporaryDirectory() + "whatshot-sync-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    var engine = makeEngine(queue: queue)
    let ticker = TickingClock(base: Date()) // 基值须在 90 天裁剪窗口内，否则观察会被 prune 删光
    engine.clock = { ticker.next() }

    let summary = await engine.run()
    #expect(summary.error == nil)
    #expect(summary.fetchedCount == 9) // 3 个榜 × 3 条，列表页为空
    #expect(summary.refreshedScopes == ["3", "4", "5"]) // 全部榜单刷新成功（分榜单新鲜度依据）

    let repo = engine.repo
    let recent = try await repo.latestChart(.recent)
    #expect(recent.count == 3)
    #expect(recent.map(\.rank) == [1, 2, 3])
    // 分榜单新鲜度：每个 scope 都有自己的批次时间
    let recentUpdated = try await repo.chartLastUpdated(.recent)
    let weeklyUpdated = try await repo.chartLastUpdated(.weekly)
    #expect(recentUpdated != nil)
    #expect(weeklyUpdated != nil)
    #expect(recentUpdated != weeklyUpdated) // 时钟逐秒前进，不同榜批次时间不同
  }

  /// 回归：写库失败不得被静默吞掉——观察表写不进去时，摘要必须报错而不是"成功"
  @Test func dbWriteFailureSurfaces() async throws {
    let tmp = NSTemporaryDirectory() + "whatshot-sync-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let engine = makeEngine(queue: queue)
    // 制造真实 SQLite 写失败：删观察表后每条 upsert 都在写观察一步抛错
    try await queue.run { db in
      try db.exec("DROP TABLE observations")
    }

    let summary = await engine.run()
    #expect(summary.error != nil)
    // 榜单批次回滚后不计入"已刷新"（分榜单新鲜度不得谎报）
    #expect(summary.refreshedScopes.isEmpty)
  }

  /// 回归：批次事务写入——中途失败整批回滚，旧榜不被半批数据替换（评估文档 4.1
  /// "写入失败不替换旧榜" 验收标准）
  @Test func batchFailureRollsBackWholeBatch() async throws {
    let tmp = NSTemporaryDirectory() + "whatshot-sync-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)

    // 先写入一批完整旧榜（rank 1-3）
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let oldBatch = [makeVideo(id: 1), makeVideo(id: 2), makeVideo(id: 3)]
      .enumerated().map { (video: $0.element, rank: $0.offset + 1) }
    _ = try await repo.upsertBatch(oldBatch, chartScope: .recent, observedAt: base)

    // 新批次第 2 条触发失败：用触发器在 video_id=2 的观察写入时 RAISE(ABORT)
    try await queue.run { db in
      try db.exec("CREATE TRIGGER fail_second_obs BEFORE INSERT ON observations WHEN NEW.video_id = 2 BEGIN SELECT RAISE(ABORT, 'simulated'); END")
    }

    let newBatch = [makeVideo(id: 1, ejs: "更新至5集"), makeVideo(id: 2), makeVideo(id: 3)]
      .enumerated().map { (video: $0.element, rank: $0.offset + 1) }
    await #expect(throws: (any Error).self) {
      _ = try await repo.upsertBatch(newBatch, chartScope: .recent, observedAt: base.addingTimeInterval(3600))
    }

    // 回滚验证：latestChart 仍是旧批次完整 3 条，且 id=1 的 ejs 没被半批写入污染
    let chart = try await repo.latestChart(.recent)
    #expect(chart.count == 3)
    #expect(chart.map(\.rank) == [1, 2, 3])
    #expect(chart[0].video.episodeStatus == "更新至9集") // 旧值原样保留，事务没有留下半批痕迹
  }

  /// 回归：名次变化口径（评估文档 4.2 规则）——首次同步不制造入榜；
  /// 只比较同 scope 两个完整批次；升/降/入榜/持平各自正确。
  /// minimumBaselineRatio=0：小批次测试不受满员阈值干扰，只测比较逻辑
  /// （满员拦截逻辑由 fragmentedBaselineDoesNotFabricateMovements 单独覆盖）
  @Test func chartMovementsRules() async throws {
    let tmp = NSTemporaryDirectory() + "whatshot-sync-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    // 首批：1,2,3 → 4,5（两个批次才能比较）
    let first = [makeVideo(id: 1), makeVideo(id: 2), makeVideo(id: 3)]
      .enumerated().map { (video: $0.element, rank: $0.offset + 1) }
    _ = try await repo.upsertBatch(first, chartScope: .recent, observedAt: base)

    // 首批只有一批：不产生任何变化事件
    let none = try await repo.chartMovements(.recent, minimumBaselineRatio: 0)
    #expect(none.isEmpty)

    // 第二批：2 升到第 1（1 降到 2），3 持平，4 新入榜顶掉 5 之外的位置
    let second = [makeVideo(id: 2), makeVideo(id: 1), makeVideo(id: 3), makeVideo(id: 4)]
      .enumerated().map { (video: $0.element, rank: $0.offset + 1) }
    _ = try await repo.upsertBatch(second, chartScope: .recent, observedAt: base.addingTimeInterval(3600))

    let movements = try await repo.chartMovements(.recent, minimumBaselineRatio: 0)
    #expect(movements[2] == VideoRepository.ChartMovement(previousRank: 2, delta: 1))  // 2→1 升
    #expect(movements[1] == VideoRepository.ChartMovement(previousRank: 1, delta: -1)) // 1→2 降
    #expect(movements[3] == nil)                                                       // 3→3 持平不报
    #expect(movements[4] == VideoRepository.ChartMovement(previousRank: nil, delta: nil)) // 入榜

    // 混入列表观察（chart_scope NULL）不影响批次比较
    _ = try await repo.upsertBatch([(video: makeVideo(id: 9), rank: nil)], chartScope: nil,
                                   observedAt: base.addingTimeInterval(7200))
    let afterList = try await repo.chartMovements(.recent, minimumBaselineRatio: 0)
    #expect(afterList[2]?.delta == 1) // 列表观察不参与榜单批次序列，结果不变
  }

  /// 回归：碎片批次不作比较基线——旧版本逐条时间戳跨秒写入的历史（如升级前
  /// "27 条 + 3 条"两个时间戳）不满足"上一批完整"，不得据此制造假 NEW/假升降
  /// （评估文档 4.2："失败、不可信结果不解释成下榜/入榜"；生产库 2026-09-14 实测
  /// 存在此类碎片，见 requirements 榜单批次一节）
  @Test func fragmentedBaselineDoesNotFabricateMovements() async throws {
    let tmp = NSTemporaryDirectory() + "whatshot-sync-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    // 完整旧批次：35 条（榜单标准容量）
    let full = (1...35).map { (video: makeVideo(id: $0), rank: $0) }
    _ = try await repo.upsertBatch(full, chartScope: .recent, observedAt: base)

    // 新批次也是完整 35 条（id 重排制造真实变化），但基线完整、应当正常报变化——先验证正常路径
    let reordered = (2...35).map { (video: makeVideo(id: $0), rank: $0 - 1) } + [(video: makeVideo(id: 1), rank: 35)]
    _ = try await repo.upsertBatch(reordered, chartScope: .recent, observedAt: base.addingTimeInterval(3600))
    let healthy = try await repo.chartMovements(.recent)
    #expect(healthy[2]?.delta == 1) // 完整基线 → 正常报告升降

    // 再写入碎片基线：模拟旧代码跨秒（30 条拆两个时间戳）
    let gap = 1800
    let fragment1 = (1...27).map { (video: makeVideo(id: 100 + $0), rank: $0) }
    _ = try await repo.upsertBatch(fragment1, chartScope: .recent, observedAt: base.addingTimeInterval(7200))
    let fragment2 = (28...30).map { (video: makeVideo(id: 100 + $0), rank: $0) }
    _ = try await repo.upsertBatch(fragment2, chartScope: .recent, observedAt: base.addingTimeInterval(7201))

    // 最新完整批次（35 条）跟碎片基线比较：碎片不满员，全部不标
    let latest = (1...35).map { (video: makeVideo(id: $0), rank: $0) }
    _ = try await repo.upsertBatch(latest, chartScope: .recent, observedAt: base.addingTimeInterval(10800))
    let movements = try await repo.chartMovements(.recent)
    #expect(movements.isEmpty) // 碎片基线（30/35）不可信：不制造任何 NEW/升降
  }

  func makeVideo(id: Int, ejs: String = "更新至9集", seed: Int = 34) -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: 380_00000 + id, title: "测试剧集\(id)", originalTitle: nil, alias: nil,
      episodeStatus: ejs, episodes: "10", definition: "WEB-1080P", years: "2026",
      classNames: "剧情", productionArea: "日本", doubanScore: "8.0", imdbNumber: nil, imdbScore: nil,
      posterURL: nil, seedCount: seed, netdiskCount: 2, seedUpdatedAt: "2026-09-11 13:00:00",
      updatedAt: "2026-09-11 13:00:00", director: nil, performer: nil, abstract: nil,
      release: nil, kind: .tvSeries
    )
  }
}