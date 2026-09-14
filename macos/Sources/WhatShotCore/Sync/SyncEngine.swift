import Foundation

/// 同步结果摘要，供 UI 展示
public struct SyncSummary: Sendable, Equatable {
  public var fetchedCount: Int
  public var changedCount: Int
  public var detailCount: Int
  public var durationSeconds: Double
  public var error: String?
  /// 本次同步中成功刷新的榜单（分榜单新鲜度：成功榜与失败榜可区分）
  public var refreshedScopes: [String]

  public init(fetchedCount: Int, changedCount: Int, detailCount: Int, durationSeconds: Double,
              error: String? = nil, refreshedScopes: [String] = []) {
    self.fetchedCount = fetchedCount
    self.changedCount = changedCount
    self.detailCount = detailCount
    self.durationSeconds = durationSeconds
    self.error = error
    self.refreshedScopes = refreshedScopes
  }
}

/// 同步引擎：热门榜 3 个 + 电影/剧集最近更新页；变化条目补拉详情；剧集首播日豆瓣补全。
/// butai0 单次运行约 10~20 个请求；豆瓣补全三档限速（稳态 10 / 积压 30 / 护栏 30）。
/// 域名故障降级：同一域名连续 2 次请求失败（4 秒以上持续不可用）即判定故障，
/// 通过 selector 换域名后从失败步骤继续同步；切不动才计入失败。
public struct SyncEngine: Sendable {
  let client: ButaiClient
  let selector: DomainSelector?
  let repo: VideoRepository
  let settings: ButaiSettings
  /// 豆瓣客户端可注入（测试用 mock）；默认懒建。主同步不依赖它，失败只计 warning
  public var douban: DoubanClient?

  /// 首播日补全三档限速（2026-09-13 实测定案，requirements.md 定案四）
  public struct PremiereBudget: Sendable {
    public var steadyPerRun: Int      // 稳态：每周期最多 10 条
    public var backlogTrigger: Int    // 积压阈值：> 30 未补全
    public var backlogPerRun: Int     // 积压清偿：放宽到 30 条
    public init(steadyPerRun: Int = 10, backlogTrigger: Int = 30, backlogPerRun: Int = 30) {
      self.steadyPerRun = steadyPerRun
      self.backlogTrigger = backlogTrigger
      self.backlogPerRun = backlogPerRun
    }
  }
  public var premiereBudget = PremiereBudget()

  /// 可注入时钟（测试用），默认当前时间
  public var clock: @Sendable () -> Date = { Date() }

  public init(client: ButaiClient, repo: VideoRepository, settings: ButaiSettings,
              selector: DomainSelector? = nil, douban: DoubanClient? = nil) {
    self.client = client
    self.selector = selector
    self.repo = repo
    self.settings = settings
    self.douban = douban
  }

  /// 带域名降级的请求执行器：连续 2 次失败换域名重试一次
  private func resilientFetch<T>(_ operation: String, _ fetch: (ButaiClient) async throws -> T) async throws -> T {
    do {
      return try await fetch(client)
    } catch {
      // 第一次失败：原域名立即重试一次（容忍瞬时抖动）
      if let retryResult = try? await fetch(client) {
        return retryResult
      }
      // 连续 2 次失败：判定域名故障，尝试降级换域名
      guard let selector else {
        throw error
      }
      let candidates = await fallbackCandidates()
      guard let probe = await selector.demoteAndPick(candidates: candidates),
            probe.baseURL != client.baseURL else {
        throw error
      }
      let newClient = ButaiClient(baseURL: probe.baseURL)
      return try await fetch(newClient)
    }
  }

  /// 降级候选 = 发布页发现域 + 内置兜底池 + 当前设置的自定义地址。
  /// 同步中途降级时不重抓发布页（AppModel 择优时已抓过，这里用兜底+自定义即可，
  /// 换域名的紧迫场景是"冠军域名故障"，兜底池已覆盖）
  private func fallbackCandidates() async -> [String] {
    DomainPool.candidates(customBaseURL: settings.baseURL)
  }

  /// 执行一次完整同步。每一步独立容错：单个榜/页失败不影响其他，最后汇总为 warning 或 failed
  public func run() async -> SyncSummary {
    let startedAt = Date()
    let runID = (try? await repo.startSyncRun(at: startedAt)) ?? 0
    var fetched = 0
    var changed = 0
    var detailCount = 0
    var failures: [String] = []
    var refreshedScopes: [String] = []

    // 1. 热门榜三个 scope（每榜一个事务批次：整批共享时间戳，写失败整批回滚不替换旧榜）
    for scope in ButaiChartScope.allCases {
      do {
        let videos = try await resilientFetch(scope.label) { client in
          try await client.fetchChart(scope)
        }
        fetched += videos.count
        let batch = videos.enumerated().map { (video: $0.element, rank: $0.offset + 1) }
        changed += try await repo.upsertBatch(batch, chartScope: scope, observedAt: clock())
        refreshedScopes.append(scope.rawValue)
      } catch {
        failures.append("[\(scope.label)] \(describe(error))")
      }
    }

    // 2. 电影/剧集最近更新页
    for kind in [ButaiKind.movie, .tvSeries] {
      let pages = kind == .movie ? settings.movieListPages : settings.tvListPages
      for page in 1...max(1, pages) {
        do {
          let videos = try await resilientFetch("\(kind == .movie ? "电影" : "剧集")第\(page)页") { client in
            try await client.fetchMovieList(mediaKind: kind, page: page)
          }
          fetched += videos.count
          let batch: [(video: ButaiVideo, rank: Int?)] = videos.map { ($0, nil) }
          changed += try await repo.upsertBatch(batch, chartScope: nil, observedAt: clock())
        } catch {
          failures.append("[\(kind == .movie ? "电影" : "剧集")第\(page)页] \(describe(error))")
          break // 一页失败说明站点或本地库异常，停止该类翻页
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
          let detail = try await resilientFetch("详情\(doubanID)") { client in
            try await client.fetchDetail(id: doubanID)
          }
          // 详情接口的 tp 与站点归类矛盾（会把剧集标成电影），只补全字段不覆盖已有分类
          _ = try await repo.upsert(detail, chartScope: nil, chartRank: nil, now: clock(), preserveKind: true)
          try await repo.markDetailSynced(videoID: detail.id, at: clock())
          detailCount += 1
        } catch {
          failures.append("[详情\(doubanID)] \(describe(error))")
        }
      }
    }

    // 4. 历史观察裁剪（保留 90 天）
    _ = try? await repo.pruneObservations(keepDays: 90, now: Date())

    // 5. 剧集首播日豆瓣补全（一期单源例外，requirements.md 定案二/四）。
    // 三档限速：稳态 10 / 积压>30 放宽 30 / 绝对护栏 30；豆瓣任何失败只计 warning，不阻断主同步
    if let douban {
      let summary = await backfillPremieres(douban: douban)
      if let warning = summary.warning {
        failures.append(warning)
      }
    }

    let finishedAt = Date()
    let duration = finishedAt.timeIntervalSince(startedAt)
    let error = failures.isEmpty ? nil : failures.joined(separator: "；")
    let status = failures.isEmpty ? "success" : (fetched > 0 ? "warning" : "failed")
    if runID > 0 {
      try? await repo.finishSyncRun(id: runID, status: status, fetched: fetched, changed: changed, error: error, at: finishedAt)
    }
    return SyncSummary(fetchedCount: fetched, changedCount: changed, detailCount: detailCount,
                       durationSeconds: duration, error: error, refreshedScopes: refreshedScopes)
  }

  /// 首播日补全结果（供摘要展示）
  public struct PremiereBackfillSummary: Sendable, Equatable {
    public var fetched: Int        // 本次尝试抓取条数
    public var withDate: Int       // 拿到首播日
    public var warning: String?
  }

  /// 补全一批首播日。返回 warning（nil = 本批无异常）。
  /// 停批规则：429 等待 Retry-After 后放弃本批；401/403/安全页立即停批——不重试不绕过
  func backfillPremieres(douban: DoubanClient) async -> PremiereBackfillSummary {
    let pending = (try? await repo.premierePendingCount()) ?? 0
    guard pending > 0 else { return PremiereBackfillSummary(fetched: 0, withDate: 0, warning: nil) }
    let limit = pending > premiereBudget.backlogTrigger ? premiereBudget.backlogPerRun : premiereBudget.steadyPerRun
    let candidates = (try? await repo.premiereCandidates(limit: limit)) ?? []
    var withDate = 0
    var blocked: String?
    for doubanId in candidates {
      do {
        let date = try await douban.fetchPremiereDate(doubanId: doubanId)
        // 无日期也记录抓取过（premiere_fetched_at 置位），避免每轮反复重查已知无日期的条目
        try? await repo.setPremiereDate(doubanId: doubanId, date: date, at: Date())
        if date != nil { withDate += 1 }
      } catch let DoubanClient.DoubanError.rateLimited(retryAfter) {
        let wait = retryAfter.map { "（等待 \($0) 秒后放弃本批）" } ?? ""
        blocked = "豆瓣限流，本批补全中止\(wait)；已补 \(withDate) 部，剩余下轮继续"
        break
      } catch DoubanClient.DoubanError.blocked(let status) {
        blocked = "豆瓣拒绝访问(HTTP \(status))，本批补全中止；已补 \(withDate) 部，剩余下轮继续"
        break
      } catch {
        // 单条网络抖动/解析异常：跳过该条继续（下一轮会重查此条）
        continue
      }
    }
    return PremiereBackfillSummary(fetched: candidates.count, withDate: withDate, warning: blocked)
  }

  func describe(_ error: Error) -> String {
    if let parse = error as? ButaiParseError { return parse.message }
    if let db = error as? DatabaseError { return db.message }
    if let client = error as? ButaiClient.ClientError { return client.message }
    let ns = error as NSError
    return ns.localizedDescription
  }
}