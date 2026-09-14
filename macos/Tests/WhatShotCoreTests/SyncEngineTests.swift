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

    let recent = try await engine.repo.latestChart(.recent)
    #expect(recent.count == 3)
    #expect(recent.map(\.rank) == [1, 2, 3])
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
  }
}