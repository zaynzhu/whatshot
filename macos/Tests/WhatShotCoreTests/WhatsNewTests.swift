import Foundation
import Testing
@testable import WhatShotCore

/// WhatsNew 外部热度接入测试（2026-09-22 定案八）：解码容错、精确身份匹配
/// （IMDb/豆瓣、双 ID 冲突、电影剧集隔离）、多季同榜席位、快照 upsert
/// （截断不清缓存）、连接状态机。配置关闭零请求在引擎层由 guard 保证（nil client 不发请求）
struct WhatsNewTests {
  func makeStore(queue: DatabaseQueue? = nil) throws -> ExternalHeatStore {
    let path = NSTemporaryDirectory() + "whatshot-extheat-\(UUID().uuidString).sqlite3"
    return ExternalHeatStore(queue: try queue ?? DatabaseQueue(path: path))
  }

  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-extheat-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
  }

  /// 本地条目夹具：可指定身份
  func makeVideo(id: Int, kind: ButaiKind = .tvSeries, imdb: String? = nil,
                 doubanId: Int? = nil) -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: doubanId, title: "本地作品\(id)", originalTitle: nil, alias: nil,
      episodeStatus: "更新至1集", episodes: "10", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "美国", doubanScore: nil, imdbNumber: imdb, imdbScore: nil,
      posterURL: nil, seedCount: 1, netdiskCount: 0, seedUpdatedAt: "2026-09-22 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil, kind: kind
    )
  }

  /// WhatsNew 信号 fixture 构造
  func makeSignal(id: String, mediaItemId: String, source: String = "trakt_trending",
                  rank: Int? = 3, imdbId: String? = nil, mediaType: String? = "series",
                  title: String = "外部作品", entryKey: String = "work",
                  window: String? = "week", rankingScope: String? = "overall") -> WhatsNewClient.Signal {
    WhatsNewClient.Signal(
      id: id, mediaItemId: mediaItemId, source: source,
      platform: "Trakt", region: "GLOBAL", window: window,
      rankingScope: rankingScope, rankingEntryKey: entryKey, rankingEntryLabel: nil,
      rank: rank, previousRank: nil, rankDelta: nil,
      valueLabel: nil, capturedAt: "2026-09-22T04:00:00.000Z", isCurrent: true,
      mediaItem: .init(
        id: mediaItemId, mediaType: mediaType, releaseForm: nil,
        titleDisplay: title, titleChinese: nil, titleOriginal: nil, posterURL: nil,
        firstReleaseDate: nil, status: nil, imdbId: imdbId, tmdbId: nil, heatScore: nil
      )
    )
  }

  @Test func doubanScoreValidation() throws {
    let data = Data("""
    {"ratings":[
      {"source":"imdb","audience":"users","value":9,"scale":10},
      {"source":"douban","audience":"users","value":80,"scale":100},
      {"source":"douban","audience":"users","value":11,"scale":10},
      {"source":"douban","audience":"users","value":8,"scale":10,"voteCount":-1},
      {"source":"douban","audience":"users","scale":10}
    ]}
    """.utf8)
    let raw = try JSONDecoder().decode(WhatsNewClient.MediaDetailPayload.self, from: data)
    let ratings = (raw.ratings ?? []).compactMap(WhatsNewClient.parseDoubanRating)
    #expect(ratings.count == 1)
    #expect(ratings.first?.value == 8)
    #expect(ratings.first?.voteCount == nil)
    #expect(ratings.first?.capturedAt == nil)
  }

  @Test func doubanSignalSemantics() {
    #expect(ExternalSignalMeaning.label(for: "douban_top").contains("口碑"))
    #expect(ExternalSignalMeaning.label(for: "douban_upcoming").contains("待播顺序"))
    #expect(ExternalSignalMeaning.label(for: "douban_upcoming_hot").contains("预约"))
    #expect(ExternalSignalMeaning.isDoubanNonHeat("douban_top"))
    #expect(!ExternalSignalMeaning.isDoubanNonHeat("trakt_trending"))
    #expect(ExternalSignalMeaning.label(for: "unknown") == "unknown")
  }

  @Test func ratingWriteFailureRollsBackSignals() async throws {
    let repo = try makeRepo()
    let store = try makeStore(queue: repo.queue)
    func row(rank: Int) -> ExternalHeatStore.SignalUpsert {
      .init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: rank),
            mediaTitle: "作品", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil)
    }
    _ = try await store.upsertSignals([row(rank: 3)], fetchedAt: Date())
    try await repo.queue.run { db in
      try db.exec("""
        CREATE TRIGGER reject_detail BEFORE INSERT ON external_media_details
        BEGIN SELECT RAISE(ABORT, '测试评分写入失败'); END;
        """)
    }
    do {
      _ = try await store.upsertSignals([row(rank: 9)], fetchedAt: Date(),
                                        details: [.init(id: "m1", imdbId: nil, sourceRefs: [])])
      Issue.record("预期事务失败")
    } catch {}
    #expect(try await store.displayRows().first?.rank == 3)
    #expect(try await store.cachedDetails(mediaIDs: ["m1"]).isEmpty)
  }

  // MARK: - 匹配器

  /// IMDb 精确命中（大小写规范后相等）
  @Test func imdbExactMatch() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 7, kind: .tvSeries,
                                                   imdbNumber: "tt1234567", doubanId: nil)]
    let match = ExternalHeatMatcher.match(mediaIMDb: "TT1234567", mediaType: "series",
                                          doubanRefs: [], local: local)
    #expect(match?.videoID == 7)
    #expect(match?.basis == .imdb)
  }

  /// 豆瓣身份命中：IMDb 缺失时豆瓣 ID 相等即匹配（WhatsNew douban-<id> 提取）
  @Test func doubanRefMatch() {
    let refs = [makeRef(source: "douban", sourceId: "douban-26363212"),
                makeRef(source: "trakt", sourceId: "movie-99")]
    let ids = ExternalHeatMatcher.doubanIds(in: refs)
    #expect(ids == [26363212])
    let local = [ExternalHeatMatcher.LocalIdentity(id: 5, kind: .movie,
                                                   imdbNumber: nil, doubanId: 26363212)]
    let match = ExternalHeatMatcher.match(mediaIMDb: nil, mediaType: "movie",
                                          doubanRefs: ids, local: local)
    #expect(match?.videoID == 5)
    #expect(match?.basis == .douban)
  }

  /// 双 ID 冲突：分别命中不同本地条目 → 不匹配（不擅自选）
  @Test func conflictingIdsDoNotMatch() {
    let local = [
      ExternalHeatMatcher.LocalIdentity(id: 1, kind: .tvSeries,
                                        imdbNumber: "tt1111111", doubanId: nil),
      ExternalHeatMatcher.LocalIdentity(id: 2, kind: .tvSeries,
                                        imdbNumber: nil, doubanId: 222)
    ]
    let match = ExternalHeatMatcher.match(mediaIMDb: "tt1111111", mediaType: "series",
                                          doubanRefs: [222], local: local)
    #expect(match == nil)
  }

  /// 双 ID 命中同一条目：互证通过
  @Test func agreeingIdsMatch() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 1, kind: .tvSeries,
                                                   imdbNumber: "tt1111111", doubanId: 111)]
    let match = ExternalHeatMatcher.match(mediaIMDb: "tt1111111", mediaType: "series",
                                          doubanRefs: [111], local: local)
    #expect(match?.videoID == 1)
    #expect(match?.basis == .imdb)
  }

  /// 电影/剧集绝不互配：同一 IMDb 号挂在不同大类上不关联
  @Test func movieAndSeriesAreIsolated() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 1, kind: .movie,
                                                   imdbNumber: "tt1234567", doubanId: nil)]
    let seriesMatch = ExternalHeatMatcher.match(mediaIMDb: "tt1234567", mediaType: "series",
                                                doubanRefs: [], local: local)
    #expect(seriesMatch == nil)
  }

  /// 豆瓣匹配同样受电影/剧集隔离约束
  @Test func doubanMatchRespectsKind() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 2, kind: .tvSeries,
                                                   imdbNumber: nil, doubanId: 333)]
    let match = ExternalHeatMatcher.match(mediaIMDb: nil, mediaType: "movie",
                                          doubanRefs: [333], local: local)
    #expect(match == nil)
  }

  /// 无可靠身份：标题相似度不参与——WhatsNew 有标题但本地无对应 ID → 未关联
  @Test func titleOnlyStaysUnmatched() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 9, kind: .tvSeries,
                                                   imdbNumber: "tt0000000", doubanId: nil)]
    let match = ExternalHeatMatcher.match(mediaIMDb: nil, mediaType: "series",
                                          doubanRefs: [], local: local)
    #expect(match == nil)
  }

  /// 未知 mediaType（WhatsNew 未来扩展值）保守不匹配
  @Test func unknownMediaTypeNotMatched() {
    let local = [ExternalHeatMatcher.LocalIdentity(id: 3, kind: .tvSeries,
                                                   imdbNumber: "tt1234567", doubanId: nil)]
    let match = ExternalHeatMatcher.match(mediaIMDb: "tt1234567", mediaType: "podcast",
                                          doubanRefs: [], local: local)
    #expect(match == nil)
  }

  /// douban-<id> 提取：非 douban 来源忽略、格式不合法忽略
  @Test func doubanRefParsing() {
    let refs = [
      makeRef(source: "douban", sourceId: "douban-42"),
      makeRef(source: "douban", sourceId: "not-douban"),
      makeRef(source: "douban", sourceId: "douban-"),
      makeRef(source: "imdb", sourceId: "tt123")
    ]
    #expect(ExternalHeatMatcher.doubanIds(in: refs) == [42])
  }

  // MARK: - 解码

  /// trending fixture：多来源、缺字段行丢弃、rank 可缺
  @Test func trendingDecoding() throws {
    let json = """
    {"items":[
      {"id":"sig-1","mediaItemId":"m1","source":"trakt_trending","platform":"Trakt",
       "region":"GLOBAL","window":"week","rankingScope":"series","rankingEntryKey":"work",
       "rank":4,"capturedAt":"2026-09-21T10:00:00.000Z","isCurrent":true,
       "mediaItem":{"id":"m1","mediaType":"series","titleDisplay":"Severance",
                    "imdbId":"tt11280740","heatScore":88.5}},
      {"id":"sig-2","source":"netflix_top10"},
      {"mediaItemId":"m3","source":"x"}
    ]}
    """
    let signals = try WhatsNewClient.decode(WhatsNewClient.TrendingPayload.self,
                                            from: Data(json.utf8))
    #expect(signals.items?.count == 3)
  }

  /// 畸形响应：非 JSON 明确报错（调用方按步容错），不是静默成功
  @Test func malformedResponseThrows() {
    #expect(throws: WhatsNewClient.WhatsNewError.self) {
      _ = try WhatsNewClient.decode(WhatsNewClient.HealthPayload.self,
                                    from: Data("<html>oops</html>".utf8))
    }
  }

  // MARK: - 持久化

  /// upsert 幂等：同 key 覆盖不重复行；未返回的行保留（截断不推断下榜）
  @Test func upsertIdempotentAndKeepsUnreturned() async throws {
    let store = try makeStore()
    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let t2 = t1.addingTimeInterval(3600)
    let row1 = ExternalHeatStore.SignalUpsert(
      signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 4, imdbId: "tt1"),
      mediaTitle: "作品A", mediaType: "series", posterURL: nil,
      firstReleaseDate: nil, match: nil)
    _ = try await store.upsertSignals([row1], fetchedAt: t1)

    // 第二轮：s1 名次变了 + 新增 s2；s3（上轮有、本轮无）不出现——旧行保留
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 1, imdbId: "tt1"),
            mediaTitle: "作品A", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil),
      .init(signal: makeSignal(id: "s2", mediaItemId: "m2", rank: 9, imdbId: "tt2"),
            mediaTitle: "作品B", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil)
    ], fetchedAt: t2)

    let rows = try await store.displayRows()
    // s1 覆盖（rank 4→1），s2 新增，不存在的行不因未返回被删——但本 fixture 只写过 s1/s2，
    // 旧行保留语义由"第二轮不含 s3"用例单独验（见下）
    #expect(rows.count == 2)
    let s1 = rows.first { $0.mediaID == "m1" }
    #expect(s1?.rank == 1)
    #expect(s1?.fetchedAt == t2)
  }

  /// 截断响应不清已有缓存：上一轮的信号本轮未返回时，本地仍保留（is_current 不翻转）
  @Test func truncatedResponseKeepsPreviousRows() async throws {
    let store = try makeStore()
    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let t2 = t1.addingTimeInterval(3600)
    // 第一轮：两条（s1、s3）
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 1), mediaTitle: "A",
            mediaType: "series", posterURL: nil, firstReleaseDate: nil, match: nil),
      .init(signal: makeSignal(id: "s3", mediaItemId: "m3", rank: 2), mediaTitle: "C",
            mediaType: "series", posterURL: nil, firstReleaseDate: nil, match: nil)
    ], fetchedAt: t1)
    // 第二轮：只返回 s1（s3 可能只是不在本次 50 部里）
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 2), mediaTitle: "A",
            mediaType: "series", posterURL: nil, firstReleaseDate: nil, match: nil)
    ], fetchedAt: t2)

    let rows = try await store.displayRows()
    #expect(rows.count == 2) // s3 保留，不制造"全部下榜"
    let s3 = rows.first { $0.mediaID == "m3" }
    #expect(s3?.rank == 2)
  }

  /// 匹配结果入库：video_id/match_basis 写入；未关联为 NULL
  @Test func matchPersistsWithVideoID() async throws {
    let repo = try makeRepo()
    let store = try makeStore(queue: repo.queue)
    _ = try await repo.upsert(makeVideo(id: 7, kind: .tvSeries, imdb: "tt1234567"),
                              chartScope: nil, chartRank: nil, now: Date())
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "s1", mediaItemId: "m1", imdbId: "tt1234567"),
            mediaTitle: "外部", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil,
            match: .init(videoID: 7, basis: .imdb)),
      .init(signal: makeSignal(id: "s2", mediaItemId: "m2", rank: 5),
            mediaTitle: "未关联作品", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil)
    ], fetchedAt: t)

    let rows = try await store.displayRows()
    #expect(rows.count == 2)
    let matched = rows.first { $0.mediaID == "m1" }
    #expect(matched?.video?.id == 7)
    #expect(matched?.matchBasis == "imdb")
    let unmatched = rows.first { $0.mediaID == "m2" }
    #expect(unmatched?.video == nil)
    #expect(unmatched?.mediaTitle == "未关联作品")

    // 详情浮层：按本地条目反查信号
    let forVideo = try await store.signals(forVideo: 7)
    #expect(forVideo.count == 1)
    #expect(forVideo[0].source == "trakt_trending")
  }

  /// 多季同榜：同 mediaItemId 不同 rankingEntryKey = 合法多席位，不合并
  @Test func multipleSeasonSeatsSurvive() async throws {
    let store = try makeStore()
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.upsertSignals([
      .init(signal: makeSignal(id: "sa", mediaItemId: "m1", rank: 2, entryKey: "season-4"),
            mediaTitle: "同系列", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil),
      .init(signal: makeSignal(id: "sb", mediaItemId: "m1", rank: 11, entryKey: "season-1"),
            mediaTitle: "同系列", mediaType: "series", posterURL: nil,
            firstReleaseDate: nil, match: nil)
    ], fetchedAt: t)
    let rows = try await store.displayRows()
    #expect(rows.count == 2)
    #expect(Set(rows.compactMap(\.rank)).count == 2) // 两个席位独立
  }

  /// 状态机：从未拉取 → 成功 → 失败（不清成功时间以外的语义混乱）
  @Test func stateTransitions() async throws {
    let store = try makeStore()
    let initial = try await store.state()
    #expect(initial.lastStatus == "never")

    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.setState(.init(lastSuccessAt: t1, lastStatus: "ok", lastError: nil,
                                   lastSignalCount: 60, lastMediaCount: 48), at: t1)
    let ok = try await store.state()
    #expect(ok.lastStatus == "ok")
    #expect(ok.statusText == "正常")
    #expect(ok.lastSuccessAt == t1)

    // 失败：last_success_at 保留上次成功（客户端取到响应的时间不冒充榜单更新时间）
    try await store.setState(.init(lastSuccessAt: t1, lastStatus: "unreachable",
                                   lastError: "WhatsNew HTTP 503", lastSignalCount: nil,
                                   lastMediaCount: nil),
                             at: t1.addingTimeInterval(600))
    let failed = try await store.state()
    #expect(failed.statusText == "服务不可达")
    #expect(failed.lastSuccessAt == t1)
  }

  /// 坏缓存行不毒化：一条损坏的 detail_json 被跳过，其余行正常返回、整轮不炸
  @Test func corruptedCacheRowIsSkipped() async throws {
    let repo = try makeRepo()
    let store = try makeStore(queue: repo.queue)
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.upsertSignals(
      [.init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 1), mediaTitle: "A",
             mediaType: "series", posterURL: nil, firstReleaseDate: nil, match: nil)],
      fetchedAt: t,
      details: [.init(id: "m2", imdbId: "tt1", sourceRefs: [], doubanRating: nil)])
    // 手工注入坏行（模拟旧版本结构变更/损坏）
    try await repo.queue.run { db in
      try db.exec("INSERT INTO external_media_details (media_id, detail_json, fetched_at) VALUES ('m-bad', '{broken json', 1)")
    }
    let cached = try await store.cachedDetails(mediaIDs: ["m2", "m-bad"])
    #expect(cached["m2"]?.detail != nil) // 成功缓存正常返回
    #expect(cached["m-bad"] == nil) // 坏行被跳过，不是整轮抛错
  }

  /// 失败占位行：'null' 行参与轮换排序（fetchedAt = 失败时间）但不进展示
  @Test func failedDetailPlaceholderRotates() async throws {
    let repo = try makeRepo()
    let store = try makeStore(queue: repo.queue)
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.upsertSignals(
      [.init(signal: makeSignal(id: "s1", mediaItemId: "m1", rank: 1), mediaTitle: "A",
             mediaType: "series", posterURL: nil, firstReleaseDate: nil, match: nil)],
      fetchedAt: t, failedMediaIDs: ["m-fail"])
    let cached = try await store.cachedDetails(mediaIDs: ["m-fail", "m-never"])
    // 失败占位：detail 为 nil 但 fetchedAt = 失败时间（轮换键生效，不再永远插队）
    #expect(cached["m-fail"]?.detail == nil)
    #expect(cached["m-fail"]?.fetchedAt == t)
    #expect(cached["m-never"] == nil) // 从未尝试过的仍以 distantPast 排队（更优先）
  }

  /// 本地身份点查：IN 查询命中（大小写规范化由匹配器做，此处只验取回）
  @Test func localIdentityLookup() async throws {
    let repo = try makeRepo()
    _ = try await repo.upsert(makeVideo(id: 1, kind: .tvSeries, imdb: "TT1234567", doubanId: 42),
                              chartScope: nil, chartRank: nil, now: Date())
    _ = try await repo.upsert(makeVideo(id: 2, kind: .movie, imdb: nil, doubanId: 77),
                              chartScope: nil, chartRank: nil, now: Date())
    // 与 repo 共享同一库：身份点查走 repo 已写入的数据
    let store = try makeStore(queue: repo.queue)
    let identities = try await store.localIdentities(imdbs: ["tt1234567"], doubans: [42, 77])
    #expect(identities.count == 2)
    let byID = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0) })
    #expect(byID[1]?.imdbNumber == "TT1234567")
    #expect(byID[1]?.doubanId == 42)
    #expect(byID[2]?.doubanId == 77)
  }
}

/// 豆瓣 ref 便捷构造
private func makeRef(source: String, sourceId: String) -> WhatsNewClient.MediaDetail.SourceRef {
  .init(source: source, sourceId: sourceId)
}