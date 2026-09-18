import Foundation
import SQLite3
import Testing
@testable import WhatShotCore

/// 海报兜底测试（2026-09-18）：站方 localhost/http 事故条目从 TMDB/豆瓣补图。
/// 覆盖：候选筛选（只收坏 URL）、写库只补坏 URL 不覆盖好 URL、upsert 防 localhost 回滚、
/// TMDB 三命中桶的 poster_path 解析、豆瓣 tv/movie 双路径 pic 解析、引擎兜底步骤
struct PosterBackfillTests {
  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-poster-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
  }

  func makeVideo(id: Int, poster: String?, doubanId: Int? = nil, imdb: String? = nil,
                 kind: ButaiKind = .tvSeries) -> ButaiVideo {
    ButaiVideo(
      id: id, doubanId: doubanId, title: "条目\(id)", originalTitle: nil, alias: nil,
      episodeStatus: "更新至9集", episodes: "12", definition: nil, years: "2026",
      classNames: "剧情", productionArea: "中国大陆", doubanScore: nil, imdbNumber: imdb, imdbScore: nil,
      posterURL: poster, seedCount: 10, netdiskCount: 0, seedUpdatedAt: "2026-09-18 10:00:00",
      updatedAt: nil, director: nil, performer: nil, abstract: nil, release: nil, kind: kind
    )
  }

  func poster(of id: Int, repo: VideoRepository) async throws -> String? {
    let rows = try await repo.listVideos(kind: .tvSeries, limit: 100, offset: 0, sort: .seedUpdated)
    if let row = rows.first(where: { $0.id == id }) { return row.posterURL }
    // 电影条目走电影查询
    let movies = try await repo.listVideos(kind: .movie, limit: 100, offset: 0, sort: .seedUpdated)
    return movies.first { $0.id == id }?.posterURL
  }

  // MARK: - 候选查询：只收坏 URL

  @Test func candidatesOnlyBadURLs() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, poster: "http://localhost:3000/a.jpg", doubanId: 101, imdb: "tt001"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, poster: "https://tu.mvinfo.homes/i/a.jpg"), chartScope: nil, chartRank: nil, now: now)  // 好 URL：不进
    _ = try await repo.upsert(makeVideo(id: 3, poster: nil, doubanId: 103), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 4, poster: "http://tu.mvinfo.homes/x.jpg", doubanId: 104), chartScope: nil, chartRank: nil, now: now) // http 明文

    let candidates = try await repo.posterBackfillCandidates(limit: 10)
    let ids = candidates.map(\.id)
    #expect(ids.contains(1))
    #expect(ids.contains(3))
    #expect(ids.contains(4))
    #expect(!ids.contains(2))
  }

  // MARK: - 写库：只补坏 URL

  @Test func writeOnlyWhenBadURL() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, poster: "http://localhost:3000/a.jpg"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, poster: "https://tu.mvinfo.homes/i/good.jpg"), chartScope: nil, chartRank: nil, now: now)

    let wrote = try await repo.setPosterBackfill(videoID: 1, url: "https://image.tmdb.org/t/p/w500/abc.jpg", at: now)
    #expect(wrote == true)
    #expect(try await poster(of: 1, repo: repo) == "https://image.tmdb.org/t/p/w500/abc.jpg")

    // 好 URL 不被兜底覆盖
    let rejected = try await repo.setPosterBackfill(videoID: 2, url: "https://image.tmdb.org/t/p/w500/xyz.jpg", at: now)
    #expect(rejected == false)
    #expect(try await poster(of: 2, repo: repo) == "https://tu.mvinfo.homes/i/good.jpg")
  }

  // MARK: - upsert 防回滚：站方再发 localhost 不得覆盖已兜底的真 URL

  @Test func upsertDoesNotRollBackToLocahost() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, poster: "http://localhost:3000/a.jpg"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.setPosterBackfill(videoID: 1, url: "https://image.tmdb.org/t/p/w500/abc.jpg", at: now)

    // 站方同条目再同步回来仍是 localhost：不覆盖
    _ = try await repo.upsert(makeVideo(id: 1, poster: "http://localhost:3000/b.jpg"), chartScope: nil, chartRank: nil, now: now)
    #expect(try await poster(of: 1, repo: repo) == "https://image.tmdb.org/t/p/w500/abc.jpg")

    // 站方修好给了真 URL：覆盖（尊重站方）
    _ = try await repo.upsert(makeVideo(id: 1, poster: "https://tu.mvinfo.homes/i/fixed.jpg"), chartScope: nil, chartRank: nil, now: now)
    #expect(try await poster(of: 1, repo: repo) == "https://tu.mvinfo.homes/i/fixed.jpg")
  }

  // MARK: - TMDB poster_path 解析（三种命中桶）

  /// movie_results 直接带 poster_path
  @Test func parseMoviePosterPath() async throws {
    let json = """
    {"movie_results":[{"poster_path":"/rayAREIKtSinuov10GvrZHyXfXH.jpg","title":"丑陋的继姐"}],
     "tv_results":[],"tv_episode_results":[]}
    """
    #expect(TmdbClient.firstPosterPath(from: Data(json.utf8), key: "movie_results") == "/rayAREIKtSinuov10GvrZHyXfXH.jpg")
  }

  /// tv_episode_results 无海报 → 经 show_id 二跳取 /tv/{id} 详情的 poster_path
  @Test func parseShowDetailPosterPath() async throws {
    let detail = #"{"id":86831,"name":"Love, Death & Robots","poster_path":"/vL5BQvXH96cJzmNK5n7QliQxy90.jpg"}"#
    #expect(TmdbClient.firstPosterPath(from: Data(detail.utf8), key: nil) == "/vL5BQvXH96cJzmNK5n7QliQxy90.jpg")
  }

  /// 脏数据防御：poster_path 非 / 开头不收
  @Test func parseRejectsMalformedPath() async throws {
    let json = #"{"movie_results":[{"poster_path":"abc.jpg"}],"tv_results":[],"tv_episode_results":[]}"#
    #expect(TmdbClient.firstPosterPath(from: Data(json.utf8), key: "movie_results") == nil)
  }

  // MARK: - 豆瓣 pic 解析

  @Test func parseDoubanPicObject() {
    let json = """
    {"title":"因果报应","pic":{"large":"https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2915350868.jpg","normal":"https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2915350868.jpg"}}
    """
    #expect(DoubanClient.parsePosterPath(from: Data(json.utf8)) == "https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2915350868.jpg")
  }

  /// 非 doubanio 域名不收（只兜豆瓣图，防止把第三方防盗链 URL 写库）
  @Test func parseRejectsForeignPic() {
    let json = #"{"pic":{"large":"http://localhost:3000/uploads/douban_1.jpg"}}"#
    #expect(DoubanClient.parsePosterPath(from: Data(json.utf8)) == nil)
  }

  /// ATS 红线：http 明文 doubanio URL 一律不收（macOS 默认策略禁明文，不豁免）
  @Test func parseRejectsPlaintextHttpDoubanio() {
    let json = #"{"pic":{"large":"http://img1.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg"}}"#
    #expect(DoubanClient.parsePosterPath(from: Data(json.utf8)) == nil)
  }

  // MARK: - 引擎兜底步骤（URLProtocol stub 全链路）

  /// TMDB + 豆瓣 stub：/find 回 movie 命中，/tv/ 404 回 movie 的 pic.large
  final class PosterStubURLProtocol: URLProtocol {
    static func makeSession() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [PosterStubURLProtocol.self]
      return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let status: Int
      let json: String
      if url.host?.contains("themoviedb.org") == true {
        if url.path.contains("/find/") {
          status = 200
          json = #"{"movie_results":[{"poster_path":"/rayAREIKtSinuov10GvrZHyXfXH.jpg"}],"tv_results":[],"tv_episode_results":[]}"#
        } else {
          status = 200
          json = #"{"id":1,"poster_path":"/showAbc.jpg"}"#
        }
      } else if url.host?.contains("douban.com") == true {
        if url.path.contains("/tv/") {
          status = 404
          json = #"{"code":404,"msg":"traversal_error"}"#
        } else {
          status = 200
          json = #"{"title":"因果报应","pic":{"large":"https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2915350868.jpg"}}"#
        }
      } else {
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

  /// 引擎兜底：有 IMDb 的走 TMDB 写入，无 IMDb 有豆瓣 ID 的走豆瓣 movie 回退写入
  @Test func engineBackfillsBothSources() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, poster: "http://localhost:3000/a.jpg", imdb: "tt111"), chartScope: nil, chartRank: nil, now: now)
    _ = try await repo.upsert(makeVideo(id: 2, poster: "http://localhost:3000/b.jpg", doubanId: 36934908, kind: .movie), chartScope: nil, chartRank: nil, now: now)

    let tmdb = TmdbClient(apiKey: "k", limiter: RateLimiter(interval: 0), session: PosterStubURLProtocol.makeSession())
    let douban = DoubanClient(limiter: RateLimiter(interval: 0), session: PosterStubURLProtocol.makeSession())
    let engine = SyncEngine(client: ButaiClient(baseURL: "https://www.butai0.club", limiter: RateLimiter(interval: 0), session: PosterStubURLProtocol.makeSession()),
                            repo: repo, settings: ButaiSettings(baseURL: "https://www.butai0.club", syncIntervalHours: 6, posterCacheLimitMB: 300, movieListPages: 1, tvListPages: 1),
                            douban: douban, tmdb: tmdb)

    let tmdbSummary = await engine.backfillPostersViaTmdb(tmdb: tmdb)
    #expect(tmdbSummary.withDate == 1)
    #expect(try await poster(of: 1, repo: repo) == "https://image.tmdb.org/t/p/w500/rayAREIKtSinuov10GvrZHyXfXH.jpg")

    let doubanSummary = await engine.backfillPostersViaDouban(douban: douban)
    #expect(doubanSummary.withDate == 1)
    #expect(try await poster(of: 2, repo: repo) == "https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2915350868.jpg")
  }
}