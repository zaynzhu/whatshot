import Foundation
import Testing
@testable import WhatShotCore

/// 外部热度同步引擎集成测试（2026-09-22）：用 URLProtocol stub 模拟 WhatsNew 服务，
/// 验证 health 验证 → trending 解码 → 匹配 → 写库 → 状态机的全链路。
/// stub 是集成验证手段，**不能替代真实服务联调**（真实覆盖未核对，交接文档如实记录）
@Suite(.serialized)
@MainActor
struct WhatsNewEngineTests {
  /// stub：按 URL path 返回预设响应，计数发过的请求
  final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let path = request.url?.path ?? ""
      Self.requestedPaths.append(path)
      guard let route = Self.routes[path] else {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        return
      }
      let response = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                     httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(route.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  func makeEngine() throws -> (SyncEngine, VideoRepository, ExternalHeatStore) {
    let tmp = NSTemporaryDirectory() + "whatshot-wnengine-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)
    let store = ExternalHeatStore(queue: queue)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = WhatsNewClient(baseURL: "http://127.0.0.1:19993",
                                limiter: RateLimiter(interval: 0.01),
                                session: URLSession(configuration: config))
    let engine = SyncEngine(client: ButaiClient(baseURL: "https://www.butai0.club"),
                            repo: repo, settings: .default, whatsnew: client)
    return (engine, repo, store)
  }

  func reset() {
    StubProtocol.routes = [:]
    StubProtocol.requestedPaths = []
  }

  func stubHealth() {
    StubProtocol.routes["/api/health"] =
      (200, #"{"ok":true,"service":"whatsnew-backend","environment":"main"}"#)
  }

  // MARK: - 成功链路

  /// health + trending → 解码、IMDb 直连匹配、事务写库、状态 ok
  @Test func successfulSyncEndToEnd() async throws {
    reset()
    stubHealth()
    StubProtocol.routes["/api/trending"] = (200, """
    {"items":[
      {"id":"s1","mediaItemId":"m1","source":"trakt_trending","platform":"Trakt",
       "region":"GLOBAL","window":"week","rankingScope":"series","rankingEntryKey":"work",
       "rank":3,"previousRank":5,"rankDelta":7,"capturedAt":"2026-09-21T10:00:00.000Z",
       "isCurrent":true,
       "mediaItem":{"id":"m1","mediaType":"series","titleDisplay":"Matched Show",
                    "imdbId":"tt1234567","heatScore":90}}
    ]}
    """)

    StubProtocol.routes["/api/media/m1"] = (200, """
    {"id":"m1","imdbId":"tt1234567","sourceRefs":[],"ratings":[
      {"source":"douban","audience":"users","value":8.2,"scale":10,"voteCount":1234,"capturedAt":"2026-09-22T01:02:03Z"}
    ]}
    """)

    let tmp = NSTemporaryDirectory() + "whatshot-wnengine2-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)
    let store = ExternalHeatStore(queue: queue)
    _ = try await repo.upsert(ButaiVideo(
      id: 7, doubanId: nil, title: "本地作品", originalTitle: nil, alias: nil,
      episodeStatus: "更新至2集", episodes: "10", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "美国", doubanScore: nil,
      imdbNumber: "tt1234567", imdbScore: nil, posterURL: nil,
      seedCount: 1, netdiskCount: 0, seedUpdatedAt: "2026-09-22 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil,
      kind: .tvSeries
    ), chartScope: nil, chartRank: nil, now: Date())

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = WhatsNewClient(baseURL: "http://127.0.0.1:19993",
                                limiter: RateLimiter(interval: 0.01),
                                session: URLSession(configuration: config))
    let engine = SyncEngine(client: ButaiClient(baseURL: "https://www.butai0.club"),
                            repo: repo, settings: .default, whatsnew: client)

    let summary = await engine.syncExternalHeat(whatsnew: client)

    // 已有 IMDb 匹配仍取详情评分，主数据与外部评分隔离
    #expect(StubProtocol.requestedPaths == ["/api/health", "/api/trending", "/api/media/m1"])
    #expect(summary.fetched == 1)
    #expect(summary.withDate == 1)
    #expect(summary.warning == nil)
    let rows = try await store.displayRows()
    #expect(rows.count == 1)
    #expect(rows[0].video?.id == 7)
    #expect(rows[0].matchBasis == "imdb")
    let state = try await store.state()
    #expect(state.lastStatus == "ok")
    #expect(state.lastSignalCount == 1)
    #expect(state.lastMediaCount == 1)
    let details = try await store.details(forVideo: 7)
    #expect(details.count == 1)
    #expect(details.first?.detail.doubanRating?.value == 8.2)
    #expect(details.first?.detail.doubanRating?.voteCount == 1234)
    #expect(details.first?.detail.doubanRating?.capturedAt == "2026-09-22T01:02:03Z")
    #expect(rows.first?.video?.doubanScore == nil)

    // 网络失败保留旧评分；成功的空评分清除旧值。
    StubProtocol.routes["/api/media/m1"] = (503, "{}")
    let failed = await engine.syncExternalHeat(whatsnew: client)
    #expect(failed.warning != nil)
    #expect(try await store.details(forVideo: 7).first?.detail.doubanRating?.value == 8.2)
    StubProtocol.routes["/api/media/m1"] = (200, #"{"id":"m1","sourceRefs":[],"ratings":[]}"#)
    _ = await engine.syncExternalHeat(whatsnew: client)
    #expect(try await store.details(forVideo: 7).first?.detail.doubanRating == nil)

  }

  @Test func detailBudgetRotatesAndCachedIdentitySurvives() async throws {
    reset()
    stubHealth()
    let (initialEngine, repo, store) = try makeEngine()
    var engine = initialEngine
    engine.whatsnewDetailBudgetPerRun = 1
    _ = try await repo.upsert(WhatsNewTests().makeVideo(id: 9, doubanId: 123),
                              chartScope: nil, chartRank: nil, now: Date())
    StubProtocol.routes["/api/trending"] = (200, """
    {"items":[
      {"id":"s1","mediaItemId":"m1","source":"douban_top","mediaItem":{"id":"m1","mediaType":"series"}},
      {"id":"s2","mediaItemId":"m1","source":"douban_upcoming_hot","mediaItem":{"id":"m1","mediaType":"series"}},
      {"id":"s3","mediaItemId":"m2","source":"trakt_trending","mediaItem":{"id":"m2","mediaType":"series"}}
    ]}
    """)
    StubProtocol.routes["/api/media/m1"] = (200, """
    {"id":"m1","sourceRefs":[{"source":"douban","sourceId":"douban-123"}],"ratings":[
      {"source":"douban","audience":"users","value":9,"scale":10}
    ]}
    """)
    StubProtocol.routes["/api/media/m2"] = (200, #"{"id":"m2","sourceRefs":[],"ratings":[]}"#)
    _ = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(StubProtocol.requestedPaths.filter { $0.hasPrefix("/api/media/") } == ["/api/media/m1"])
    #expect(try await store.details(forVideo: 9).count == 1)
    StubProtocol.requestedPaths = []
    _ = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(StubProtocol.requestedPaths.filter { $0.hasPrefix("/api/media/") } == ["/api/media/m2"])
    #expect(try await store.displayRows().filter { $0.video?.id == 9 }.count == 2)
    #expect(try await store.details(forVideo: 9).first?.detail.doubanRating?.value == 9)
  }

  @Test func detailConflictDoesNotExposeRating() async throws {
    reset()
    stubHealth()
    let (engine, repo, store) = try makeEngine()
    _ = try await repo.upsert(WhatsNewTests().makeVideo(id: 1, imdb: "tt111"),
                              chartScope: nil, chartRank: nil, now: Date())
    _ = try await repo.upsert(WhatsNewTests().makeVideo(id: 2, doubanId: 222),
                              chartScope: nil, chartRank: nil, now: Date())
    StubProtocol.routes["/api/trending"] = (200, """
    {"items":[{"id":"s1","mediaItemId":"m1","source":"trakt_trending",
    "mediaItem":{"id":"m1","mediaType":"series","imdbId":"tt111"}}]}
    """)
    StubProtocol.routes["/api/media/m1"] = (200, """
    {"id":"m1","sourceRefs":[{"source":"douban","sourceId":"douban-222"}],
    "ratings":[{"source":"douban","audience":"users","value":8,"scale":10}]}
    """)
    _ = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(try await store.displayRows().first?.video == nil)
    #expect(try await store.details(forVideo: 1).isEmpty)
    #expect(try await store.details(forVideo: 2).isEmpty)
  }

  // MARK: - 失败路径

  /// 服务不对：health 返回别的 service → bad_service，零信号写入
  @Test func wrongServiceIsRejected() async throws {
    reset()
    StubProtocol.routes["/api/health"] =
      (200, #"{"ok":true,"service":"other-service","environment":"x"}"#)
    let (engine, _, store) = try makeEngine()
    let summary = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(summary.fetched == 0)
    #expect(summary.warning != nil)
    let state = try await store.state()
    #expect(state.lastStatus == "bad_service")
  }

  /// 服务不可达（stub 无路由 = 连接失败）→ unreachable；**不清已有缓存**
  @Test func unreachableKeepsCache() async throws {
    reset()
    let (engine, _, store) = try makeEngine()
    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    // 先造一次成功快照
    try await store.setState(.init(lastSuccessAt: t1, lastStatus: "ok", lastError: nil,
                                   lastSignalCount: 5, lastMediaCount: 5), at: t1)
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "s9", mediaItemId: "m9", rank: 4),
            mediaTitle: "缓存条目", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil)
    ], fetchedAt: t1)

    // 本轮：health 都连不上（routes 空）
    let summary = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(summary.fetched == 0)
    #expect(summary.warning != nil)
    let state = try await store.state()
    #expect(state.lastStatus == "unreachable")
    #expect(state.lastSuccessAt == t1) // 上次成功时间保留，不冒充本次
    let rows = try await store.displayRows()
    #expect(rows.count == 1) // 缓存不清空，不制造"全部下榜"
    #expect(rows[0].mediaTitle == "缓存条目")
  }

  /// 畸形 trending 响应 → invalid_response，不写库
  @Test func malformedTrendingIsRecorded() async throws {
    reset()
    stubHealth()
    StubProtocol.routes["/api/trending"] = (200, "<html>not json</html>")
    let (engine, _, store) = try makeEngine()
    let summary = await engine.syncExternalHeat(whatsnew: makeClient())
    #expect(summary.fetched == 0)
    let state = try await store.state()
    #expect(["invalid_response", "unreachable"].contains(state.lastStatus))
    #expect(try await store.displayRows().isEmpty)
  }

  // MARK: - 夹具

  func makeSignal(id: String, mediaItemId: String, rank: Int) -> WhatsNewClient.Signal {
    WhatsNewClient.Signal(
      id: id, mediaItemId: mediaItemId, source: "trakt_trending",
      platform: "Trakt", region: "GLOBAL", window: "week",
      rankingScope: "overall", rankingEntryKey: "work", rankingEntryLabel: nil,
      rank: rank, previousRank: nil, rankDelta: nil,
      valueLabel: nil, capturedAt: "2026-09-21T10:00:00.000Z", isCurrent: true,
      mediaItem: .init(id: mediaItemId, mediaType: "series", releaseForm: nil,
                       titleDisplay: "标题", titleChinese: nil, titleOriginal: nil,
                       posterURL: nil, firstReleaseDate: nil, status: nil,
                       imdbId: nil, tmdbId: nil, heatScore: nil)
    )
  }

  /// 测试直接构造 client 传入 syncExternalHeat（不依赖引擎字段可空性）
  func makeClient() -> WhatsNewClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return WhatsNewClient(baseURL: "http://127.0.0.1:19993",
                          limiter: RateLimiter(interval: 0.01),
                          session: URLSession(configuration: config))
  }
}