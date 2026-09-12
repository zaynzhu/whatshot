import Foundation

/// 同步结果摘要，供 UI 展示
public struct SyncSummary: Sendable, Equatable {
  public var fetchedCount: Int
  public var changedCount: Int
  public var detailCount: Int
  public var durationSeconds: Double
  public var error: String?
}

/// 同步引擎：热门榜 3 个 + 电影/剧集最近更新页；变化条目补拉详情。
/// 单次运行约 10~20 个请求，2 秒限频下一分钟内完成。
public struct SyncEngine: Sendable {
  let client: ButaiClient
  let repo: VideoRepository
  let settings: ButaiSettings

  public init(client: ButaiClient, repo: VideoRepository, settings: ButaiSettings) {
    self.client = client
    self.repo = repo
    self.settings = settings
  }

  /// 执行一次完整同步。每一步独立容错：单个榜/页失败不影响其他，最后汇总为 warning 或 failed
  public func run() async -> SyncSummary {
    let startedAt = Date()
    let runID = (try? await repo.startSyncRun(at: startedAt)) ?? 0
    var fetched = 0
    var changed = 0
    var detailCount = 0
    var failures: [String] = []

    // 1. 热门榜三个 scope
    for scope in ButaiChartScope.allCases {
      do {
        let videos = try await client.fetchChart(scope)
        fetched += videos.count
        for (index, video) in videos.enumerated() {
          let videoChanged = (try? await repo.upsert(video, chartScope: scope, chartRank: index + 1, now: Date())) ?? false
          if videoChanged { changed += 1 }
        }
      } catch {
        failures.append("[\(scope.label)] \(describe(error))")
      }
    }

    // 2. 电影/剧集最近更新页
    for kind in [ButaiKind.movie, .tvSeries] {
      let pages = kind == .movie ? settings.movieListPages : settings.tvListPages
      for page in 1...max(1, pages) {
        do {
          let videos = try await client.fetchMovieList(mediaKind: kind, page: page)
          fetched += videos.count
          for video in videos {
            let videoChanged = (try? await repo.upsert(video, chartScope: nil, chartRank: nil, now: Date())) ?? false
            if videoChanged { changed += 1 }
          }
        } catch {
          failures.append("[\(kind == .movie ? "电影" : "剧集")第\(page)页] \(describe(error))")
          break // 一页失败说明站点可能异常，停止该类翻页
        }
      }
    }

    // 3. 变化或新条目补拉详情（导演/演员/简介/总集数），每轮上限 20 条避免单次同步过长
    // getVideoDetail 的 id 参数是豆瓣 ID（站点 idcode），不是站点内部数字 ID
    if fetched > 0 || failures.isEmpty {
      let candidates = (try? await repo.detailRefreshCandidates(limit: 20, detailStaleHours: 168)) ?? []
      for doubanID in candidates {
        guard doubanID > 0 else { continue } // 无豆瓣 ID 的条目无法拉详情
        do {
          let detail = try await client.fetchDetail(id: doubanID)
          // 详情接口的 tp 与站点归类矛盾（会把剧集标成电影），只补全字段不覆盖已有分类
          _ = try? await repo.upsert(detail, chartScope: nil, chartRank: nil, now: Date(), preserveKind: true)
          try? await repo.markDetailSynced(videoID: detail.id, at: Date())
          detailCount += 1
        } catch {
          failures.append("[详情\(doubanID)] \(describe(error))")
        }
      }
    }

    // 4. 历史观察裁剪（保留 90 天）
    _ = try? await repo.pruneObservations(keepDays: 90, now: Date())

    let finishedAt = Date()
    let duration = finishedAt.timeIntervalSince(startedAt)
    let error = failures.isEmpty ? nil : failures.joined(separator: "；")
    let status = failures.isEmpty ? "success" : (fetched > 0 ? "warning" : "failed")
    if runID > 0 {
      try? await repo.finishSyncRun(id: runID, status: status, fetched: fetched, changed: changed, error: error, at: finishedAt)
    }
    return SyncSummary(fetchedCount: fetched, changedCount: changed, detailCount: detailCount, durationSeconds: duration, error: error)
  }

  func describe(_ error: Error) -> String {
    if let parse = error as? ButaiParseError { return parse.message }
    if let db = error as? DatabaseError { return db.message }
    if let client = error as? ButaiClient.ClientError { return client.message }
    let ns = error as NSError
    return ns.localizedDescription
  }
}