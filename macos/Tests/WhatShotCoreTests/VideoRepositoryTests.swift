import Foundation
import Testing
@testable import WhatShotCore

/// 本地库测试：upsert 变更检测、历史观察、榜单快照、中断收尾
struct VideoRepositoryTests {
  func makeRepo() throws -> VideoRepository {
    let tmp = NSTemporaryDirectory() + "whatshot-tests-\(UUID().uuidString).sqlite3"
    let queue = try DatabaseQueue(path: tmp)
    return VideoRepository(queue: queue)
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

  /// 首次入库不算变化；同状态重复不变化；ejs 或 seed 变化才报告变化
  @Test func upsertChangeDetection() async throws {
    let repo = try makeRepo()
    let now = Date()
    let first = try await repo.upsert(makeVideo(id: 1), chartScope: nil, chartRank: nil, now: now)
    #expect(!first)
    let same = try await repo.upsert(makeVideo(id: 1), chartScope: nil, chartRank: nil, now: now)
    #expect(!same)
    let advanced = try await repo.upsert(makeVideo(id: 1, ejs: "更新至10集"), chartScope: nil, chartRank: nil, now: now)
    #expect(advanced)
    let seedGrown = try await repo.upsert(makeVideo(id: 1, ejs: "更新至10集", seed: 40), chartScope: nil, chartRank: nil, now: now)
    #expect(seedGrown)
  }

  /// 每次观察都写入历史，能按时间倒序读出
  @Test func observationHistory() async throws {
    let repo = try makeRepo()
    let now = Date()
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至9集"), chartScope: .weekly, chartRank: 5, now: now)
    _ = try await repo.upsert(makeVideo(id: 1, ejs: "更新至10集"), chartScope: nil, chartRank: nil, now: now.addingTimeInterval(60))
    let rows = try await repo.observations(videoID: 1)
    #expect(rows.count == 2)
    #expect(rows.first?.ejs == "更新至10集")
    #expect(rows.last?.chartRank == 5)
  }

  /// 榜单快照取同 scope 最近一个 observed_at 的全部名次
  @Test func latestChart() async throws {
    let repo = try makeRepo()
    let now = Date()
    for rank in 1...3 {
      _ = try await repo.upsert(makeVideo(id: rank, ejs: "全集"), chartScope: .recent, chartRank: rank, now: now)
    }
    _ = try await repo.upsert(makeVideo(id: 9), chartScope: .weekly, chartRank: 1, now: now.addingTimeInterval(30))
    let recent = try await repo.latestChart(.recent)
    #expect(recent.count == 3)
    #expect(recent.map(\.rank) == [1, 2, 3])
    #expect(recent[0].video.id == 1)
    let weekly = try await repo.latestChart(.weekly)
    #expect(weekly.count == 1)
    #expect(weekly[0].video.id == 9)
  }

  /// 中断收尾 + 数据库文件可统计
  @Test func recoverInterruptedRunsAndSize() async throws {
    let repo = try makeRepo()
    _ = try await repo.startSyncRun(at: Date())
    try await repo.recoverInterruptedRuns(at: Date())
    let size = try await repo.databaseFileSize()
    #expect(size > 0)
  }

  /// 历史裁剪按天删除
  @Test func pruneObservations() async throws {
    let repo = try makeRepo()
    let now = Date()
    let old = now.addingTimeInterval(-100 * 86400)
    _ = try await repo.upsert(makeVideo(id: 1), chartScope: nil, chartRank: nil, now: old)
    _ = try await repo.upsert(makeVideo(id: 2), chartScope: nil, chartRank: nil, now: now)
    let deleted = try await repo.pruneObservations(keepDays: 90, now: now)
    #expect(deleted == 1)
    let remaining = try await repo.observations(videoID: 1)
    #expect(remaining.isEmpty) // id=1 的唯一观察已超过 90 天被裁掉
    let kept = try await repo.observations(videoID: 2)
    #expect(kept.count == 1) // id=2 的新观察保留
  }

  /// 列表分页按 seed_updated_at 降序
  @Test func listVideosPaging() async throws {
    let repo = try makeRepo()
    let now = Date()
    for id in 1...5 {
      var video = makeVideo(id: id)
      video.seedUpdatedAt = "2026-09-0\(6 - id + 1) 10:00:00"
      _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    }
    let firstPage = try await repo.listVideos(kind: .tvSeries, limit: 3, offset: 0)
    #expect(firstPage.count == 3)
    #expect(firstPage[0].id == 1)
    let secondPage = try await repo.listVideos(kind: .tvSeries, limit: 3, offset: 3)
    #expect(secondPage.count == 2)
    let movies = try await repo.listVideos(kind: .movie, limit: 10, offset: 0)
    #expect(movies.isEmpty)
  }

  /// 详情候选按 seed_updated_at 新到旧，返回豆瓣 ID（详情接口参数）
  @Test func detailRefreshCandidates() async throws {
    let repo = try makeRepo()
    let now = Date()
    for id in 1...3 {
      var video = makeVideo(id: id)
      video.seedUpdatedAt = "2026-09-\(10 + id) 10:00:00" // id 越大越新
      _ = try await repo.upsert(video, chartScope: nil, chartRank: nil, now: now)
    }
    let candidates = try await repo.detailRefreshCandidates(limit: 2, detailStaleHours: 168)
    #expect(candidates == [38000003, 38000002])
  }
}