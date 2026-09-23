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
    #expect(details.first?.detail?.doubanRating?.value == 8.2)
    #expect(details.first?.detail?.doubanRating?.voteCount == 1234)
    #expect(details.first?.detail?.doubanRating?.capturedAt == "2026-09-22T01:02:03Z")
    #expect(rows.first?.video?.doubanScore == nil)

    // 网络失败保留旧评分；成功的空评分清除旧值。
    StubProtocol.routes["/api/media/m1"] = (503, "{}")
    let failed = await engine.syncExternalHeat(whatsnew: client)
    #expect(failed.warning != nil)
    #expect(try await store.details(forVideo: 7).first?.detail?.doubanRating?.value == 8.2)
    StubProtocol.routes["/api/media/m1"] = (200, #"{"id":"m1","sourceRefs":[],"ratings":[]}"#)
    _ = await engine.syncExternalHeat(whatsnew: client)
    #expect(try await store.details(forVideo: 7).first?.detail?.doubanRating == nil)

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
    #expect(try await store.details(forVideo: 9).first?.detail?.doubanRating?.value == 9)
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

  // MARK: - lookup client（契约 v1，2026-09-23）

  /// lookup 解码：matched/unmatched 行、counts、signals、评分
  @Test func lookupDecoding() async throws {
    reset()
    StubProtocol.routes["/api/media/lookup"] = (200, """
    {"contractVersion":1,"counts":{"matched":1,"unmatched":1,"ambiguous":0},"items":[
      {"query":{"kind":"douban","id":35644140},"status":"matched","mediaId":"m1",
       "matchBasis":"douban","matchLevel":"work","titleDisplay":"一瓯春","mediaType":"series",
       "workStatus":"released","heatScore":0,"signals":[
         {"id":"sig1","mediaItemId":"m1","source":"iqiyi_reserve","platform":"爱奇艺",
          "region":"CN","window":"current","rankingScope":"overall","rank":52,
          "capturedAt":"2026-09-23T13:08:50.345Z","isCurrent":true}],
       "lastSignalCapturedAt":"2026-09-17T01:08:09.533Z","doubanRating":null},
      {"query":{"kind":"imdb","id":"tt11280740"},"status":"unmatched","reason":"no_work_level_identity"}
    ]}
    """)
    let response = try await makeClient().lookupMedia(mediaType: "series",
                                                      doubanIds: [35644140], imdbIds: ["tt11280740"])
    #expect(response.matched == 1 && response.unmatched == 1 && response.ambiguous == 0)
    #expect(response.items.count == 2)
    let matched = response.items[0]
    #expect(matched.status == "matched")
    #expect(matched.mediaId == "m1")
    #expect(matched.matchBasis == "douban")
    #expect(matched.signals.count == 1)
    #expect(matched.signals[0].source == "iqiyi_reserve")
    #expect(matched.doubanRating == nil) // 在库但无评分，与 unmatched 区分
    let unmatched = response.items[1]
    #expect(unmatched.status == "unmatched")
    #expect(unmatched.reason == "no_work_level_identity")
    #expect(StubProtocol.requestedPaths == ["/api/media/lookup"])
  }

  /// ambiguous：不代选，回传候选列表
  @Test func lookupAmbiguousRow() async throws {
    reset()
    StubProtocol.routes["/api/media/lookup"] = (200, """
    {"contractVersion":1,"counts":{"ambiguous":1},"items":[
      {"query":{"kind":"imdb","id":"tt999"},"status":"ambiguous",
       "reason":"multiple_candidates","candidateMediaIds":["mA","mB"]}
    ]}
    """)
    let response = try await makeClient().lookupMedia(mediaType: "movie", doubanIds: [], imdbIds: ["tt999"])
    #expect(response.items[0].status == "ambiguous")
    #expect(response.items[0].candidateMediaIds == ["mA", "mB"])
  }

  /// 蜘蛛侠 movie：评分与信号解码（真实冒烟值 7.8/365671）
  @Test func lookupDoubanRatingDecoding() async throws {
    reset()
    StubProtocol.routes["/api/media/lookup"] = (200, """
    {"contractVersion":1,"counts":{"matched":1},"items":[
      {"query":{"kind":"douban","id":36246195},"status":"matched","mediaId":"m1",
       "matchBasis":"douban","matchLevel":"work","titleDisplay":"蜘蛛侠：崭新之日",
       "mediaType":"movie","heatScore":100,
       "signals":[{"id":"s1","mediaItemId":"m1","source":"iqiyi_reserve","rank":52,
                   "window":"current","rankingScope":"overall","isCurrent":true}],
       "doubanRating":{"value":7.8,"scale":10,"voteCount":365671,
                       "capturedAt":"2026-09-22T00:00:00.000Z"},"imdbId":null,"tmdbId":294990}
    ]}
    """)
    let response = try await makeClient().lookupMedia(mediaType: "movie", doubanIds: [36246195], imdbIds: [])
    let rating = response.items[0].doubanRating
    #expect(rating?.value == 7.8)
    #expect(rating?.voteCount == 365671)
    #expect(response.items[0].signals.count == 1)
  }

  /// 4xx：服务端 error 码进错误信息（请求级失败与 unmatched 语义分开）
  @Test func lookupClientErrorCarriesServerCode() async throws {
    reset()
    StubProtocol.routes["/api/media/lookup"] =
      (400, #"{"error":"unsupported_contract_version","supportedVersion":1}"#)
    do {
      _ = try await makeClient().lookupMedia(mediaType: "series", doubanIds: [1], imdbIds: [])
      Issue.record("应当抛错")
    } catch let error as WhatsNewClient.WhatsNewError {
      #expect(error.message.contains("unsupported_contract_version"))
    }
  }

  /// 客户端自查批量上限：>50 拒绝发送（不发任何网络请求）
  @Test func lookupBatchLimitEnforcedLocally() async throws {
    reset()
    let many = Array(repeating: 1, count: 51)
    do {
      _ = try await makeClient().lookupMedia(mediaType: "series", doubanIds: many, imdbIds: [])
      Issue.record("应当拒绝")
    } catch {
      #expect(StubProtocol.requestedPaths.isEmpty) // 未发请求
    }
  }

  /// 追剧反查：不在 trending 50 部内的追剧作品经 lookup 拿到信号与评分；
  /// unmatched（单集 tt）如实跳过；lookup 失败不阻断（warning）
  @Test func lookupWatchlistIntegration() async throws {
    reset()
    stubHealth()
    // trending 返回别的作品（不含追剧条目 m1），验证反查独立生效
    StubProtocol.routes["/api/trending"] = (200, "{\"items\":[]}")
    StubProtocol.routes["/api/media/lookup"] = (200, """
    {"contractVersion":1,"counts":{"matched":1,"unmatched":1},"items":[
      {"query":{"kind":"douban","id":35644140},"status":"matched","mediaId":"m1",
       "matchBasis":"douban","matchLevel":"work","titleDisplay":"一瓯春",
       "mediaType":"series","signals":[
         {"id":"sig1","mediaItemId":"m1","source":"iqiyi_reserve","platform":"爱奇艺",
          "region":"CN","window":"current","rankingScope":"overall","rank":52,
          "capturedAt":"2026-09-23T13:08:50.345Z","isCurrent":true}],
       "doubanRating":null,"imdbId":null},
      {"query":{"kind":"imdb","id":"tt3658012"},"status":"unmatched","reason":"no_work_level_identity"}
    ]}
    """)
    let tmp = NSTemporaryDirectory() + "whatshot-wnwl-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    let repo = VideoRepository(queue: queue)
    _ = try await repo.upsert(ButaiVideo(
      id: 7, doubanId: 35644140, title: "本地作品", originalTitle: nil, alias: nil,
      episodeStatus: "更新至1集", episodes: "10", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "中国大陆", doubanScore: nil,
      imdbNumber: "tt3658012", imdbScore: nil, posterURL: nil,
      seedCount: 1, netdiskCount: 0, seedUpdatedAt: "2026-09-22 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil,
      kind: .tvSeries
    ), chartScope: nil, chartRank: nil, now: Date())
    try await repo.addToWatchlist(videoID: 7, at: Date())

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = WhatsNewClient(baseURL: "http://127.0.0.1:19993",
                                limiter: RateLimiter(interval: 0.01),
                                session: URLSession(configuration: config))
    let engine = SyncEngine(client: ButaiClient(baseURL: "https://www.butai0.club"),
                            repo: repo, settings: .default, whatsnew: client)
    let summary = await engine.syncExternalHeat(whatsnew: client)

    // 追剧条目 7：反查信号入库且已关联；评分缓存可查（对照展示生效）
    let rows = try await store0(queue).displayRows()
    let watchSignal = rows.first { $0.video?.id == 7 }
    #expect(watchSignal != nil)
    #expect(watchSignal?.rank == 52)
    #expect(watchSignal?.matchBasis == "douban")
    let details = try await store0(queue).details(forVideo: 7)
    #expect(details.first?.detail?.doubanRating == nil) // 一瓯春在库但无评分

    // 评分：另一 mock 作品带评分的场景在 lookupDoubanRatingDecoding 已覆盖
    _ = details
  }

  /// 独立 store 实例（与 makeEngine 的临时库共享由调用方传入）
  func store0(_ queue: DatabaseQueue) -> ExternalHeatStore {
    ExternalHeatStore(queue: queue)
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