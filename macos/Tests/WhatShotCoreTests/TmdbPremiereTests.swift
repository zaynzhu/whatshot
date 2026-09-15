import Foundation
import SQLite3
import Testing
@testable import WhatShotCore

/// TMDB 首播日补全测试（2026-09-15 一期例外扩大，方案 B：该季首播日）
/// 解析逻辑对照 userscript douban-ratings 实测样例；集成测试用 URLProtocol stub 拦截网络。
struct TmdbPremiereTests {
  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-tmdb-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
  }

  func makeVideo(id: Int, title: String, imdb: String?, doubanId: Int? = nil) -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: doubanId, title: title, originalTitle: nil, alias: nil,
      episodeStatus: "更新至9集", episodes: "12", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "美国", doubanScore: nil, imdbNumber: imdb, imdbScore: nil,
      posterURL: nil, seedCount: 10, netdiskCount: 0, seedUpdatedAt: "2026-09-15 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil, kind: .tvSeries
    )
  }

  // MARK: - 季号解析（搬 userscript getSeasonNumber + parseChineseNumber）

  @Test func parseSeasonNumberChinese() {
    #expect(TmdbClient.parseSeasonNumber(from: "黑袍纠察队 第四季") == 4)
    #expect(TmdbClient.parseSeasonNumber(from: "仙逆 第一季") == 1)
    #expect(TmdbClient.parseSeasonNumber(from: "黄石 第五季") == 5)
    #expect(TmdbClient.parseSeasonNumber(from: "老友记 第十季") == 10)
  }

  @Test func parseSeasonNumberChineseCompound() {
    #expect(TmdbClient.parseSeasonNumber(from: "某某 第十一季") == 11)
    #expect(TmdbClient.parseSeasonNumber(from: "某某 第二十季") == 20)
    #expect(TmdbClient.parseSeasonNumber(from: "某某 第二十一季") == 21)
  }

  @Test func parseSeasonNumberEnglish() {
    #expect(TmdbClient.parseSeasonNumber(from: "The Boys Season 4") == 4)
  }

  @Test func parseSeasonNumberAbsent() {
    #expect(TmdbClient.parseSeasonNumber(from: "最后生还者") == nil)   // 无季号
    #expect(TmdbClient.parseSeasonNumber(from: "夜魔侠：重生 第一季") == 1)
  }

  // MARK: - /find 解析

  /// 实测样例：最后生还者 tt26469967 → tv_episode_results S2E1
  @Test func parseEpisodeHit() {
    let json = """
    {"movie_results":[],"tv_results":[],"tv_episode_results":[
      {"id":5517228,"show_id":100088,"season_number":2,"episode_number":1,"air_date":"2025-04-13"}
    ]}
    """
    let hit = TmdbClient.firstEpisode(from: Data(json.utf8))
    #expect(hit?.showId == 100088)
    #expect(hit?.seasonNumber == 2)
    #expect(hit?.episodeNumber == 1)
    #expect(hit?.airDate == "2025-04-13")
  }

  /// 实测样例：夜魔侠重生 tt18923754 → tv_results 系列级
  @Test func parseSeriesHit() {
    let json = """
    {"movie_results":[],"tv_episode_results":[],"tv_results":[
      {"id":202555,"name":"夜魔侠：重生","first_air_date":"2025-03-04"}
    ]}
    """
    let data = Data(json.utf8)
    #expect(TmdbClient.firstEpisode(from: data) == nil)
    #expect(TmdbClient.firstTvShowId(from: data) == 202555)
    #expect(TmdbClient.firstTvFirstAirDate(from: data) == "2025-03-04")
  }

  /// 全空 → 无匹配
  @Test func parseEmpty() {
    let json = #"{"movie_results":[],"tv_results":[],"tv_episode_results":[]}"#
    let data = Data(json.utf8)
    #expect(TmdbClient.firstEpisode(from: data) == nil)
    #expect(TmdbClient.firstTvShowId(from: data) == nil)
  }

  /// 坏 JSON / 缺字段容错
  @Test func parseMalformed() {
    #expect(TmdbClient.firstEpisode(from: Data("not json".utf8)) == nil)
    // 单集缺 air_date → nil（不硬填）
    let noDate = Data(#"{"tv_episode_results":[{"show_id":1,"season_number":1,"episode_number":1,"air_date":""}]}"#.utf8)
    #expect(TmdbClient.firstEpisode(from: noDate) == nil)
  }

  // MARK: - 日期规范化

  @Test func normalizeDateStrict() {
    #expect(TmdbClient.normalizeDate("2025-04-13") == "2025-04-13")
    #expect(TmdbClient.normalizeDate("2025") == nil)      // 仅年份不补假日期
    #expect(TmdbClient.normalizeDate("") == nil)
    #expect(TmdbClient.normalizeDate(nil) == nil)
    #expect(TmdbClient.normalizeDate("2025/04/13") == nil)
  }

  // MARK: - 写库护栏：只补空不覆盖豆瓣 + 按 imdb 定位

  @Test func setPremiereByImdbOnlyWhenEmpty() async throws {
    let repo = try makeRepo()
    let now = Date()
    // 条目1：已有豆瓣日期，TMDB 不得覆盖
    _ = try await repo.upsert(makeVideo(id: 1, title: "最后生还者 第二季", imdb: "tt26469967", doubanId: 1001), chartScope: nil, chartRank: nil, now: now)
    try await repo.setPremiereDate(doubanId: 1001, date: "2025-04-14", source: "douban", at: now)

    let overwritten = try await repo.setPremiereByImdb(imdbNumber: "tt26469967", date: "2025-04-13", at: now)
    #expect(overwritten == false)                       // 已有日期：不写
    let info1 = try await repo.premiereInfo(videoID: 1)
    #expect(info1?.date == "2025-04-14")                 // 豆瓣值保留
    #expect(info1?.source == "douban")

    // 条目2：无日期，TMDB 补入并记 source
    _ = try await repo.upsert(makeVideo(id: 2, title: "权游 第五季", imdb: "tt3658012", doubanId: nil), chartScope: nil, chartRank: nil, now: now)
    let written = try await repo.setPremiereByImdb(imdbNumber: "tt3658012", date: "2015-04-12", at: now)
    #expect(written == true)
    let info2 = try await repo.premiereInfo(videoID: 2)
    #expect(info2?.date == "2015-04-12")
    #expect(info2?.source == "tmdb")
  }

  // MARK: - TMDB 候选查询（有 IMDb、无日期）

  @Test func tmdbCandidatesFilter() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, title: "A 第一季", imdb: "tt001"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, title: "B", imdb: nil), chartScope: nil, chartRank: nil, now: now)            // 无 IMDb：不进
    _ = try await repo.upsert(makeVideo(id: 3, title: "C 第三季", imdb: "tt003"), chartScope: nil, chartRank: nil, now: now)
    // 条目1 已有日期：不进候选
    _ = try await repo.upsert(makeVideo(id: 4, title: "D", imdb: "tt004"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.setPremiereByImdb(imdbNumber: "tt004", date: "2026-01-01", at: now)

    let candidates = try await repo.tmdbPremiereCandidates(limit: 10)
    let imdbs = candidates.map(\.imdb)
    #expect(imdbs.contains("tt001"))
    #expect(imdbs.contains("tt003"))
    #expect(!imdbs.contains("tt004"))                   // 已有日期排除
    #expect(!candidates.contains { $0.title == "B" })   // 无 IMDb 排除
    #expect(try await repo.tmdbPremierePendingCount() == 2)
  }

  // MARK: - 集成：/find → 分季日期 全链路（URLProtocol stub）

  /// TMDB stub：/find 回单集命中，/season 回该季 air_date
  final class TmdbStubURLProtocol: URLProtocol {
    static let findEpisodeJSON = """
    {"movie_results":[],"tv_results":[],"tv_episode_results":[
      {"id":5517228,"show_id":100088,"season_number":2,"episode_number":1,"air_date":"2025-04-13"}
    ]}
    """
    static let findSeriesJSON = """
    {"movie_results":[],"tv_episode_results":[],"tv_results":[
      {"id":202555,"name":"夜魔侠：重生","first_air_date":"2025-03-04"}
    ]}
    """
    static let seasonJSON = #"{"season_number":2,"name":"第 2 季","air_date":"2025-04-13"}"#

    static let apiKey = "test-bearer-token"

    static func makeSession() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [TmdbStubURLProtocol.self]
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
      if url.path.contains("/find/") {
        let imdb = url.lastPathComponent.components(separatedBy: "?").first ?? ""
        json = imdb == "tt26469967" ? Self.findEpisodeJSON : Self.findSeriesJSON
      } else if url.path.contains("/season/") {
        json = Self.seasonJSON
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

  /// 单集命中且 ep==1：直接用 air_date，不再调 season
  @Test func fetchEpisodeDirectSeasonPremiere() async throws {
    let client = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: TmdbStubURLProtocol.makeSession())
    let premiere = try await client.fetchSeasonPremiere(imdbId: "tt26469967", title: "最后生还者 第二季")
    #expect(premiere.date == "2025-04-13")
    #expect(premiere.showId == 100088)
    #expect(premiere.seasonNumber == 2)
  }

  /// 季号校验：标题是第二季但 IMDb 是第二季单集 → 一致，采信
  @Test func fetchSeasonMatchesTitle() async throws {
    let client = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: TmdbStubURLProtocol.makeSession())
    // stub 的 findEpisode 是 S2，标题"第二季"季号 2，匹配
    let premiere = try await client.fetchSeasonPremiere(imdbId: "tt26469967", title: "某某 第二季")
    #expect(premiere.seasonNumber == 2)
  }

  /// 季号校验：标题第三季但 IMDb 给的是 S2 单集 → 季号不符，抛 notFound 不硬填
  @Test func fetchSeasonMismatchRejected() async throws {
    let client = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: TmdbStubURLProtocol.makeSession())
    do {
      _ = try await client.fetchSeasonPremiere(imdbId: "tt26469967", title: "某某 第三季")
      Issue.record("季号不符应抛 notFound")
    } catch TmdbClient.TmdbError.notFound {
      // 预期
    }
  }

  /// 系列命中：夜魔侠 tt18923754 → tv_results，无季号默认第1季 = first_air_date
  @Test func fetchSeriesFirstSeason() async throws {
    let client = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: TmdbStubURLProtocol.makeSession())
    let premiere = try await client.fetchSeasonPremiere(imdbId: "tt18923754", title: "夜魔侠：重生")
    #expect(premiere.date == "2025-03-04")
    #expect(premiere.showId == 202555)
    #expect(premiere.seasonNumber == 1)
  }

  /// 系列命中但标题带季号：走 /season/N 取季级日期
  @Test func fetchSeriesWithTitleSeason() async throws {
    let client = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: TmdbStubURLProtocol.makeSession())
    // stub: 非 tt26469967 的 /find 都回 findSeries（showId=202555），/season/2 回 2025-04-13
    let premiere = try await client.fetchSeasonPremiere(imdbId: "tt999999", title: "某某 第二季")
    #expect(premiere.date == "2025-04-13")
    #expect(premiere.seasonNumber == 2)
  }
}
