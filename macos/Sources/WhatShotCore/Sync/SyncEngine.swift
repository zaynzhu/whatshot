import Foundation

/// 同步结果摘要，供 UI 展示
public struct SyncSummary: Sendable, Equatable {
  /// success：全部成功；warning：主数据成功但有部分步骤失败（如豆瓣 403）；
  /// failed：一条数据都没拿到。UI 按 status 区分红色错误与琥珀提示
  public enum Status: String, Sendable, Equatable {
    case success, warning, failed
    /// 用户手动停止：主数据批次已提交保留，补全步骤未跑完（定案七：取消不留伪成功状态）
    case stopped
  }

  public var status: Status
  public var fetchedCount: Int
  public var changedCount: Int
  public var detailCount: Int
  public var durationSeconds: Double
  public var error: String?
  /// 本次同步中成功刷新的榜单（分榜单新鲜度：成功榜与失败榜可区分）
  public var refreshedScopes: [String]
  /// 各步骤明细（同步详情浮层展示）：时间点 + 步骤 + 结果
  public var steps: [SyncStep]

  public init(status: Status, fetchedCount: Int, changedCount: Int, detailCount: Int, durationSeconds: Double,
              error: String? = nil, refreshedScopes: [String] = [], steps: [SyncStep] = []) {
    self.status = status
    self.fetchedCount = fetchedCount
    self.changedCount = changedCount
    self.detailCount = detailCount
    self.durationSeconds = durationSeconds
    self.error = error
    self.refreshedScopes = refreshedScopes
    self.steps = steps
  }

  /// 单步骤记录：状态浮层里逐行展示"几点几分 · 干了什么 · 结果如何"
  public struct SyncStep: Sendable, Equatable, Identifiable {
    public var id: Int
    /// 展示名（"近日热门" / "剧集第2页" / "首播日补全"）
    public var label: String
    /// ok=成功；partial=该步骤部分完成（豆瓣被拦但已补 N 部）；failed=整步失败
    public var outcome: String
    /// 补充数字（拉取条数/已补部数），失败时为 nil
    public var count: Int?

    public init(id: Int, label: String, outcome: String, count: Int? = nil) {
      self.id = id
      self.label = label
      self.outcome = outcome
      self.count = count
    }
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
  /// TMDB 客户端可注入（一期例外扩大，2026-09-15）；nil/未配 key 时跳过该步。失败只计 warning
  public var tmdb: TmdbClient?

  /// 首播日补全三档限速（2026-09-13 实测定案；2026-09-15 稳态 10→12，requirements.md 定案四）
  public struct PremiereBudget: Sendable {
    /// 稳态：每周期最多 12 条。
    /// 实测 403 拦在第 13/14 条（douban_requests 观测 2026-09-15，触线约 13~14），
    /// 12 条贴触线下方留一条缝：比 10 快一点，又不顶风控。保守起见不超 13。
    public var steadyPerRun: Int
    public var backlogTrigger: Int    // 积压阈值：> 30 未补全
    public var backlogPerRun: Int     // 积压清偿：放宽到 30 条
    public init(steadyPerRun: Int = 12, backlogTrigger: Int = 30, backlogPerRun: Int = 30) {
      self.steadyPerRun = steadyPerRun
      self.backlogTrigger = backlogTrigger
      self.backlogPerRun = backlogPerRun
    }
  }
  public var premiereBudget = PremiereBudget()

  /// 可注入时钟（测试用），默认当前时间
  public var clock: @Sendable () -> Date = { Date() }

  /// 实时进度回调（定案七）：每步开始/补全推进时触发（label, 已完成数）。
  /// AppModel 转发到主线程展示"同步中 · 某阶段 · 已补 N"。回调在同步 Task 上执行，勿做重活
  public var onProgress: (@Sendable (_ label: String, _ count: Int?) -> Void)?

  /// 追剧检查每轮上限（定案七）：detail 接口 2 秒限频下 20 条约 40 秒；
  /// 关注较多时分轮刷新（最久未检查优先），多数追剧作品仍在活跃范围被常规同步覆盖
  public var watchlistBudgetPerRun = 20

  private func progress(_ label: String, _ count: Int? = nil) {
    onProgress?(label, count)
  }

  public init(client: ButaiClient, repo: VideoRepository, settings: ButaiSettings,
              selector: DomainSelector? = nil, douban: DoubanClient? = nil, tmdb: TmdbClient? = nil,
              s3: S3Client? = nil, whatsnew: WhatsNewClient? = nil) {
    self.client = client
    self.selector = selector
    self.repo = repo
    self.settings = settings
    self.douban = douban
    self.tmdb = tmdb
    self.s3 = s3
    self.whatsnew = whatsnew
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
    var steps: [SyncSummary.SyncStep] = []
    var stepID = 0

    // 1. 热门榜三个 scope（每榜一个事务批次：整批共享时间戳，写失败整批回滚不替换旧榜）
    for scope in ButaiChartScope.allCases {
      if Task.isCancelled { break } // 手动停止：在步骤边界退出，已提交批次保留
      do {
        progress("拉取\(scope.label)")
        let videos = try await resilientFetch(scope.label) { client in
          try await client.fetchChart(scope)
        }
        fetched += videos.count
        let batch = videos.enumerated().map { (video: $0.element, rank: $0.offset + 1) }
        changed += try await repo.upsertBatch(batch, chartScope: scope, observedAt: clock())
        refreshedScopes.append(scope.rawValue)
        stepID += 1
        steps.append(SyncSummary.SyncStep(id: stepID, label: scope.label, outcome: "ok", count: videos.count))
      } catch {
        failures.append("[\(scope.label)] \(describe(error))")
        stepID += 1
        steps.append(SyncSummary.SyncStep(id: stepID, label: scope.label, outcome: "failed"))
      }
    }

    // 2. 电影/剧集最近更新页
    for kind in [ButaiKind.movie, .tvSeries] {
      if Task.isCancelled { break }
      let kindLabel = kind == .movie ? "电影" : "剧集"
      let pages = kind == .movie ? settings.movieListPages : settings.tvListPages
      var kindCount = 0
      var kindFailed = false
      for page in 1...max(1, pages) {
        if Task.isCancelled { break }
        do {
          progress("拉取\(kindLabel)第\(page)页")
          let videos = try await resilientFetch("\(kindLabel)第\(page)页") { client in
            try await client.fetchMovieList(mediaKind: kind, page: page)
          }
          fetched += videos.count
          kindCount += videos.count
          let batch: [(video: ButaiVideo, rank: Int?)] = videos.map { ($0, nil) }
          changed += try await repo.upsertBatch(batch, chartScope: nil, observedAt: clock())
        } catch {
          failures.append("[\(kindLabel)第\(page)页] \(describe(error))")
          kindFailed = true
          break // 一页失败说明站点或本地库异常，停止该类翻页
        }
      }
      stepID += 1
      steps.append(SyncSummary.SyncStep(id: stepID, label: "\(kindLabel)最近更新",
                                        outcome: kindFailed ? "partial" : "ok", count: kindCount))
    }

    // 3. 变化或新条目补拉详情（导演/演员/简介/总集数），每轮上限 20 条避免单次同步过长
    // getVideoDetail 的 id 参数是豆瓣 ID（站点 idcode），不是站点内部数字 ID
    var detailFailed = 0
    if fetched > 0 || failures.isEmpty {
      let candidates = (try? await repo.detailRefreshCandidates(limit: 20, detailStaleHours: 168)) ?? []
      for doubanID in candidates {
        if Task.isCancelled { break }
        guard doubanID > 0 else { continue } // 无豆瓣 ID 的条目无法拉详情
        do {
          progress("详情补拉", detailCount)
          let detail = try await resilientFetch("详情\(doubanID)") { client in
            try await client.fetchDetail(id: doubanID)
          }
          // 详情接口的 tp 与站点归类矛盾（会把剧集标成电影），只补全字段不覆盖已有分类
          _ = try await repo.upsert(detail, chartScope: nil, chartRank: nil, now: clock(), preserveKind: true)
          try await repo.markDetailSynced(videoID: detail.id, at: clock())
          detailCount += 1
        } catch {
          detailFailed += 1
          failures.append("[详情\(doubanID)] \(describe(error))")
        }
      }
    }
    stepID += 1
    steps.append(SyncSummary.SyncStep(id: stepID, label: "条目详情补拉",
                                      outcome: detailFailed == 0 ? "ok" : "partial",
                                      count: detailFailed == 0 ? detailCount : nil))

    // 3b. 追剧条目检查（定案七）：离开热门榜与最近更新页的作品靠 detail 单条刷新保持最新，
    // 最久未检查优先、每轮 ≤ watchlistBudgetPerRun。失败只计 warning，不阻断
    let watchlist = await refreshWatchlist()
    stepID += 1
    steps.append(SyncSummary.SyncStep(id: stepID, label: "追剧检查",
                                      outcome: watchlist.failed == 0 ? "ok" : "partial",
                                      count: watchlist.checked))
    if watchlist.failed > 0 {
      failures.append("追剧检查 \(watchlist.failed) 条失败，下轮自动重试")
    }

    // 4. 剧集首播日豆瓣补全（一期单源例外，requirements.md 定案二/四）。
    // 三档限速：稳态 10 / 积压>30 放宽 30 / 绝对护栏 30；豆瓣任何失败只计 warning，不阻断主同步。
    // 限频 6.5±1.5s 随机抖动（2s 等差节奏两天 195 条后触发 403，红队审查 2026-09-14）
    if let douban {
      let summary = await backfillPremieres(douban: douban, runId: runID)
      if let warning = summary.warning {
        failures.append(warning)
      }
      stepID += 1
      // partial = 被拦但已补一部分；no_date 不算失败，withDate 只统计拿到日期的
      let outcome = summary.warning == nil ? "ok" : "partial"
      steps.append(SyncSummary.SyncStep(id: stepID, label: "首播日补全",
                                        outcome: outcome, count: summary.withDate))
    }

    // 4b. TMDB 首播日补全（一期例外扩大，2026-09-15 定案，方案 B）。
    // 只补有 IMDb 的剧集分季首播日；与豆瓣补的是不同子集（TMDB 走 imdb_number 身份）。
    // 豆瓣 403 退避期间这条路径把欧美分季剧先补齐。失败只计 warning，不阻断主同步。
    if let tmdb {
      let summary = await backfillPremieresViaTmdb(tmdb: tmdb)
      if let warning = summary.warning {
        failures.append(warning)
      }
      stepID += 1
      let outcome = summary.warning == nil ? "ok" : "partial"
      steps.append(SyncSummary.SyncStep(id: stepID, label: "TMDB 首播日",
                                        outcome: outcome, count: summary.withDate))
    }

    // 4c. 海报兜底（2026-09-18）：站方 localhost/http 事故条目补图。
    // 有 IMDb 走 TMDB（官方图床无防盗链）；其余有豆瓣 ID 走豆瓣 rexxar（pic 字段，
    // doubanio 图床下载需 Referer——PosterLoader 按域名加头）。只补坏 URL 不覆盖好 URL；
    // 豆瓣路径沿用首播日护栏（每轮 ≤30）与观测表，TMDB 一轮扫完。失败只计 warning。
    if let tmdb {
      let summary = await backfillPostersViaTmdb(tmdb: tmdb)
      if let warning = summary.warning {
        failures.append(warning)
      }
      stepID += 1
      let outcome = summary.warning == nil ? "ok" : "partial"
      steps.append(SyncSummary.SyncStep(id: stepID, label: "TMDB 海报兜底",
                                        outcome: outcome, count: summary.withDate))
    }
    if let douban {
      let summary = await backfillPostersViaDouban(douban: douban, runId: runID)
      if let warning = summary.warning {
        failures.append(warning)
      }
      stepID += 1
      let outcome = summary.warning == nil ? "ok" : "partial"
      steps.append(SyncSummary.SyncStep(id: stepID, label: "豆瓣海报兜底",
                                        outcome: outcome, count: summary.withDate))
    }

    // 4d. 外部热度（2026-09-22 WhatsNew 可选接入）：health 验证 + trending +
    // IMDb 直连匹配 + 有限 detail 补豆瓣身份 + 事务写库。独立 2 秒限频，
    // 任何失败只计 warning 不阻断主同步；未配置/关闭时 whatsnew == nil 整步跳过零请求
    if let whatsnew {
      let summary = await syncExternalHeat(whatsnew: whatsnew)
      if let warning = summary.warning {
        failures.append(warning)
      }
      stepID += 1
      let outcome = summary.warning == nil ? "ok" : "partial"
      steps.append(SyncSummary.SyncStep(id: stepID, label: "外部热度",
                                        outcome: outcome, count: summary.fetched))
    }

    // 5. 历史观察裁剪（保留 90 天，豆瓣请求记录同口径）
    _ = try? await repo.pruneObservations(keepDays: 90, now: Date())
    _ = try? await repo.pruneDoubanRequests(keepDays: 90, now: Date())

    let finishedAt = Date()
    let duration = finishedAt.timeIntervalSince(startedAt)
    // 手动停止：在途请求抛出的取消类错误不算失败；主数据批次已提交保留，如实标注"已停止"
    let cancelled = Task.isCancelled
    if cancelled {
      failures = failures.filter { !$0.contains("cancelled") }
    }
    let error = failures.isEmpty ? nil : failures.joined(separator: "；")
    let status: SyncSummary.Status = cancelled ? .stopped
      : (failures.isEmpty ? .success : (fetched > 0 ? .warning : .failed))
    if runID > 0 {
      try? await repo.finishSyncRun(id: runID, status: cancelled ? "stopped" : status.rawValue,
                                    fetched: fetched, changed: changed, error: error, at: finishedAt)
    }
    return SyncSummary(status: status, fetchedCount: fetched, changedCount: changed, detailCount: detailCount,
                       durationSeconds: duration, error: error, refreshedScopes: refreshedScopes, steps: steps)
  }

  /// 首播日补全结果（供摘要展示）
  public struct PremiereBackfillSummary: Sendable, Equatable {
    public var fetched: Int        // 本次尝试抓取条数
    public var withDate: Int       // 拿到首播日
    public var warning: String?
  }

  /// 补全一批首播日。返回 warning（nil = 本批无异常）。
  /// 停批规则：429 等待 Retry-After 后放弃本批；401/403/安全页立即停批——不重试不绕过。
  /// 每条请求无条件写 douban_requests（风控观测，只写不读）
  func backfillPremieres(douban: DoubanClient, runId: Int = 0) async -> PremiereBackfillSummary {
    let pending = (try? await repo.premierePendingCount()) ?? 0
    guard pending > 0 else { return PremiereBackfillSummary(fetched: 0, withDate: 0, warning: nil) }
    let limit = pending > premiereBudget.backlogTrigger ? premiereBudget.backlogPerRun : premiereBudget.steadyPerRun
    let candidates = (try? await repo.premiereCandidates(limit: limit)) ?? []
    var withDate = 0
    var blocked: String?
    for (index, doubanId) in candidates.enumerated() {
      if Task.isCancelled { break }
      do {
        let date = try await douban.fetchPremiereDate(doubanId: doubanId)
        // 无日期也记录抓取过（premiere_fetched_at 置位），避免每轮反复重查已知无日期的条目
        try? await repo.setPremiereDate(doubanId: doubanId, date: date, at: clock())
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: 200,
                                            outcome: date == nil ? "no_date" : "got_date", runId: runId, at: clock())
        if date != nil { withDate += 1 }
      } catch let DoubanClient.DoubanError.rateLimited(retryAfter) {
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: 429,
                                            outcome: "rate_limited", runId: runId, at: clock())
        let wait = retryAfter.map { "（等待 \($0) 秒后放弃本批）" } ?? ""
        blocked = "豆瓣限流，本批补全中止\(wait)；已补 \(withDate) 部，剩余下轮继续"
        break
      } catch DoubanClient.DoubanError.blocked(let status) {
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: status,
                                            outcome: "blocked", runId: runId, at: clock())
        blocked = "豆瓣拒绝访问(HTTP \(status))，本批补全中止；已补 \(withDate) 部，剩余下轮继续"
        break
      } catch {
        // 单条网络抖动/解析异常：跳过该条继续（下一轮会重查此条）
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: nil,
                                            outcome: "error", runId: runId, at: clock())
        continue
      }
    }
    return PremiereBackfillSummary(fetched: candidates.count, withDate: withDate, warning: blocked)
  }

  /// TMDB 首播日补全（方案 B）：只补有 IMDb 的剧集分季首播日。
  /// 写库用 setPremiereByImdb——只补 premiere_date 为空的，豆瓣已写的不动。
  /// 无匹配/季号不符的条目留空（不置 fetched 位），留豆瓣退避后重查；401（key 无效）整批停止。
  /// 不阻断主同步，最多只在本步 warning 标注。
  func backfillPremieresViaTmdb(tmdb: TmdbClient) async -> PremiereBackfillSummary {
    let pending = (try? await repo.tmdbPremierePendingCount()) ?? 0
    guard pending > 0 else { return PremiereBackfillSummary(fetched: 0, withDate: 0, warning: nil) }
    // TMDB 一轮扫完所有待补（2026-09-15 用户定案）：官方限流宽松（约每秒几十次），
    // 不复用豆瓣的三档小步限速——豆瓣用 12 条是防它的 403 计数器，TMDB 没这回事，
    // 且有 IMDb 的条目量小（实测 25 部），一轮补完避免欧美剧跨好几轮才齐
    let limit = pending
    let candidates = (try? await repo.tmdbPremiereCandidates(limit: limit)) ?? []
    var withDate = 0
    var blocked: String?
    for candidate in candidates {
      if Task.isCancelled { break }
      do {
        let premiere = try await tmdb.fetchSeasonPremiere(imdbId: candidate.imdb, title: candidate.title)
        // 只补空不覆盖豆瓣；写入成功计数（已有豆瓣日期的返回 false 不算新增）
        let wrote = try await repo.setPremiereByImdb(imdbNumber: candidate.imdb, date: premiere.date, at: clock())
        if wrote { withDate += 1 }
      } catch TmdbClient.TmdbError.unauthorized {
        blocked = "TMDB API Key 无效(401)，本批补全中止；已补 \(withDate) 部"
        break
      } catch TmdbClient.TmdbError.notFound {
        // TMDB 无此条目/季号不符：留空，等豆瓣退避后重查此条
        continue
      } catch {
        // 单条网络抖动：跳过该条继续
        continue
      }
    }
    return PremiereBackfillSummary(fetched: candidates.count, withDate: withDate, warning: blocked)
  }

  /// 海报兜底常量：豆瓣路径每轮上限。稳态 30（9-19 实测两轮 30 条全 200 无 403）；
  /// 积压 >100 条时放宽 60/轮清偿（站方 img.mvinfo 事故存量 500+ 条，30/轮要 4 天+，
  /// 60/轮约 2 天清完；403 停批保护兜底，最坏损失一轮）
  public struct PosterBudget: Sendable {
    public var doubanPerRun: Int
    public var backlogTrigger: Int
    public var backlogPerRun: Int
    public init(doubanPerRun: Int = 30, backlogTrigger: Int = 100, backlogPerRun: Int = 60) {
      self.doubanPerRun = doubanPerRun
      self.backlogTrigger = backlogTrigger
      self.backlogPerRun = backlogPerRun
    }
  }
  public var posterBudget = PosterBudget()

  /// S3 镜像客户端（2026-09-18 海报镜像定案）。nil = 未配置，兜底直写外源 URL。
  /// 配置后兜底取到的图先传桶（poster_url 改写为桶 URL）：外源图床（豆瓣 doubanio）有
  /// 防盗链/生命周期风险，自有桶是持久层，同一 key 只传一次
  public var s3: S3Client?

  /// WhatsNew 外部热度客户端（2026-09-22 可选接入）：nil = 未配置/关闭，整步跳过零请求。
  /// 独立 2 秒限频；任何失败只计 warning，不阻断主同步与追剧
  public var whatsnew: WhatsNewClient?
  /// 外部热度 detail 补查每轮上限（给 trending 未匹配条目补豆瓣身份），
  /// 2 秒限频下 10 条约 20 秒——有限批量，不逐卡片触发请求风暴
  public var whatsnewDetailBudgetPerRun = 10

  /// 把外源海报镜像到 S3 桶。返回应写库的 URL（桶 URL）；镜像失败/未配 S3 返回原 URL。
  /// 桶是持久层：上传失败不阻断兜底（降级直写外源 URL），S3 401/403 抛 unauthorized 停批。
  /// 降级写的外源 https 下轮仍满足待镜像候选（posterBackfillCandidates 的 https 分支），
  /// 桶恢复后自动补做镜像
  private func mirrorPosterIfNeeded(sourceURL: String, videoID: Int) async throws -> String {
    guard let s3Client = s3 else { return sourceURL }
    // 已是桶 URL 的不重复镜像（防兜底循环上传）
    if sourceURL.hasPrefix(s3Client.endpoint + "/" + s3Client.bucket) { return sourceURL }
    guard let url = URL(string: sourceURL) else { return sourceURL }
    var request = URLRequest(url: url, timeoutInterval: 20)
    // doubanio 防盗链：无 Referer 返回 418（实测 2026-09-18）
    if url.host?.hasSuffix("doubanio.com") == true {
      request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
      request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let contentType = http.value(forHTTPHeaderField: "Content-Type"),
          !data.isEmpty else {
      return sourceURL // 图拉不到（外源抖动）：直写原 URL，下轮再试镜像
    }
    let key = "posters/\(videoID).jpg"
    do {
      return try await s3Client.mirror(data: data, contentType: contentType, key: key)
    } catch S3Client.S3Error.unauthorized {
      throw S3Client.S3Error.unauthorized
    } catch {
      return sourceURL // 桶暂不可达（NAS 关机等）：降级直写原 URL
    }
  }

  /// TMDB 海报兜底：对候选里带 IMDb 的条目取 poster_path，拼 w500 URL 写库。
  /// 写库只补坏 URL（空/localhost/http，配 S3 时含待镜像 https），站方中途修好则跳过；
  /// 无匹配留待下轮豆瓣路径。配置了 S3 时图先镜像到桶、写桶 URL
  func backfillPostersViaTmdb(tmdb: TmdbClient) async -> PremiereBackfillSummary {
    let mirrorPrefix = s3.map { "\($0.endpoint)/\($0.bucket)/" }
    let candidates = (try? await repo.posterBackfillCandidates(limit: 200, mirrorPrefix: mirrorPrefix)) ?? []
    let withImdb = candidates.filter { let imdb = $0.imdb; return imdb != nil && imdb?.hasPrefix("tt") == true }
    guard !withImdb.isEmpty else { return PremiereBackfillSummary(fetched: 0, withDate: 0, warning: nil) }
    var withDate = 0
    var blocked: String?
    for candidate in withImdb {
      if Task.isCancelled { break }
      guard let imdb = candidate.imdb else { continue }
      do {
        guard let path = try await tmdb.fetchPosterPath(imdbId: imdb) else { continue }
        let source = "https://image.tmdb.org/t/p/w500\(path)"
        let url = try await mirrorPosterIfNeeded(sourceURL: source, videoID: candidate.id)
        let wrote = try await repo.setPosterBackfill(videoID: candidate.id, url: url, at: clock(),
                                                     allowHttpsOverwrite: s3 != nil)
        if wrote { withDate += 1 }
      } catch TmdbClient.TmdbError.unauthorized {
        blocked = "TMDB API Key 无效(401)，海报兜底中止；已补 \(withDate) 条"
        break
      } catch S3Client.S3Error.unauthorized {
        blocked = "S3 访问被拒(401/403)，海报兜底中止；已补 \(withDate) 条"
        break
      } catch {
        continue // 单条抖动跳过，下轮重试
      }
    }
    return PremiereBackfillSummary(fetched: withImdb.count, withDate: withDate, warning: blocked)
  }

  /// 豆瓣海报兜底：对候选里无 IMDb（TMDB 够不着）但有豆瓣 ID 的条目，取 rexxar pic.large 写库。
  /// tv 路径 404 回退 movie（库内 kind 与豆瓣 kind 不一致实测存在）；每轮 ≤ posterBudget 上限，
  /// 请求写 douban_requests 观测表（outcome=poster_got/poster_404），403/429 停批不绕过。
  /// 配置了 S3 时图先镜像到桶、写桶 URL
  func backfillPostersViaDouban(douban: DoubanClient, runId: Int = 0) async -> PremiereBackfillSummary {
    let mirrorPrefix = s3.map { "\($0.endpoint)/\($0.bucket)/" }
    let candidates = (try? await repo.posterBackfillCandidates(limit: 200, mirrorPrefix: mirrorPrefix)) ?? []
    let needDouban = candidates.filter { ($0.imdb == nil || $0.imdb?.hasPrefix("tt") != true) && $0.doubanId != nil && $0.doubanId! > 0 }
    guard !needDouban.isEmpty else { return PremiereBackfillSummary(fetched: 0, withDate: 0, warning: nil) }
    // 积压清偿：坏 URL 存量超过阈值时放宽本轮上限（新条目稳态用小步）
    let perRun = needDouban.count > posterBudget.backlogTrigger ? posterBudget.backlogPerRun : posterBudget.doubanPerRun
    var withDate = 0
    var blocked: String?
    for (index, candidate) in needDouban.prefix(perRun).enumerated() {
      if Task.isCancelled { break }
      guard let doubanId = candidate.doubanId else { continue }
      do {
        guard let source = try await douban.fetchPosterPath(doubanId: doubanId) else {
          try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: 404,
                                              outcome: "poster_404", runId: runId, at: clock())
          continue
        }
        let url = try await mirrorPosterIfNeeded(sourceURL: source, videoID: candidate.id)
        if try await repo.setPosterBackfill(videoID: candidate.id, url: url, at: clock(),
                                            allowHttpsOverwrite: s3 != nil) {
          withDate += 1
        }
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: 200,
                                            outcome: "poster_got", runId: runId, at: clock())
      } catch let DoubanClient.DoubanError.rateLimited(retryAfter) {
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: 429,
                                            outcome: "rate_limited", runId: runId, at: clock())
        let wait = retryAfter.map { "（等待 \($0) 秒后放弃本批）" } ?? ""
        blocked = "豆瓣限流，海报兜底中止\(wait)；已补 \(withDate) 条，剩余下轮继续"
        break
      } catch DoubanClient.DoubanError.blocked(let status) {
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: status,
                                            outcome: "blocked", runId: runId, at: clock())
        blocked = "豆瓣拒绝访问(HTTP \(status))，海报兜底中止；已补 \(withDate) 条，剩余下轮继续"
        break
      } catch S3Client.S3Error.unauthorized {
        blocked = "S3 访问被拒(401/403)，海报兜底中止；已补 \(withDate) 条"
        break
      } catch {
        try? await repo.recordDoubanRequest(doubanId: doubanId, batchIndex: index + 1, httpStatus: nil,
                                            outcome: "error", runId: runId, at: clock())
        continue
      }
    }
    return PremiereBackfillSummary(fetched: needDouban.count, withDate: withDate, warning: blocked)
  }

  /// 追剧条目检查：detail 单条刷新（与常规详情补拉同通道，2 秒限频共享）。
  /// 最久未检查优先；单条失败静默跳过（条目失效类失败会每轮重复，计总量 warning 而非逐条噪声）
  func refreshWatchlist() async -> (checked: Int, failed: Int) {
    guard watchlistBudgetPerRun > 0 else { return (0, 0) }
    let candidates = (try? await repo.watchlistDetailCandidates(limit: watchlistBudgetPerRun)) ?? []
    var checked = 0
    var failed = 0
    for candidate in candidates {
      if Task.isCancelled { break }
      do {
        progress("追剧检查", checked)
        let detail = try await resilientFetch("追剧\(candidate.doubanId)") { client in
          try await client.fetchDetail(id: candidate.doubanId)
        }
        // 与常规详情补拉同口径：只补全字段不覆盖已有分类
        _ = try await repo.upsert(detail, chartScope: nil, chartRank: nil, now: clock(), preserveKind: true)
        try await repo.markDetailSynced(videoID: detail.id, at: clock())
        checked += 1
      } catch {
        failed += 1
      }
    }
    return (checked, failed)
  }

  /// 外部热度同步结果（复用 PremiereBackfillSummary 结构：
  /// fetched=信号条数，withDate=匹配到本地条目数，warning=失败摘要）
  func syncExternalHeat(whatsnew: WhatsNewClient) async -> PremiereBackfillSummary {
    let store = ExternalHeatStore(queue: repo.queue)
    let fetchedAt = clock()
    do {
      // 1. 服务身份验认：HTML、错误服务或沙箱占位都不算成功
      _ = try await whatsnew.fetchHealth()

      // 2. trending（无筛选 = 工作中心视图：≤50 部活跃作品及其全部当前信号）
      let signals = try await whatsnew.fetchTrending()

      // 3. 本地身份点查（点查 IN 命中，不全量载入——8GB 内存约束）
      let imdbs = signals.compactMap { $0.mediaItem?.imdbId }
      let identities = (try? await store.localIdentities(imdbs: imdbs, doubans: [])) ?? []
      var matches: [String: ExternalHeatMatcher.Match] = [:]
      var doubanRefs: [String: [Int]] = [:]      // mediaItemId → 豆瓣 subject 数字
      var needDetail: [String: (imdbId: String?, mediaType: String?)] = [:]

      for signal in signals {
        guard let media = signal.mediaItem else { continue }
        let match = ExternalHeatMatcher.match(mediaIMDb: media.imdbId,
                                              mediaType: media.mediaType,
                                              doubanRefs: [], local: identities)
        if let match {
          matches[signal.id] = match
        } else {
          // 未匹配：本轮对其作品（每 media 只一次）限量查 detail 补豆瓣身份
          needDetail[media.id] = (media.imdbId, media.mediaType)
        }
      }

      // 4. 有限 detail 补查豆瓣 refs（预算内、2 秒限频在客户端内；失败跳过该条）
      var matchedCount = matches.values.map(\.videoID).count
      for mediaID in needDetail.keys.prefix(whatsnewDetailBudgetPerRun) {
        if Task.isCancelled { break }
        guard let info = needDetail[mediaID] else { continue }
        let refs: [WhatsNewClient.MediaDetail.SourceRef]
        do {
          let detail = try await whatsnew.fetchMediaDetail(id: mediaID)
          refs = detail.sourceRefs
        } catch {
          continue // 单条抖动/未覆盖跳过，下轮重试；不是致命失败
        }
        let doubanIds = ExternalHeatMatcher.doubanIds(in: refs)
        guard !doubanIds.isEmpty else { continue }
        let local = (try? await store.localIdentities(imdbs: [], doubans: doubanIds)) ?? []
        for signal in signals where signal.mediaItemId == mediaID {
          if matches[signal.id] == nil,
             let match = ExternalHeatMatcher.match(mediaIMDb: info.imdbId,
                                                   mediaType: info.mediaType,
                                                   doubanRefs: doubanIds, local: local) {
            matches[signal.id] = match
            matchedCount += 1
          }
        }
      }

      // 5. 事务写库（一个成功响应一个事务；不删除本次未返回的行——
      // trending 50 条截断下"未返回"只能解释为范围未覆盖）
      let rows = signals.map { signal -> ExternalHeatStore.SignalUpsert in
        let media = signal.mediaItem
        return ExternalHeatStore.SignalUpsert(
          signal: signal,
          mediaTitle: media?.titleDisplay ?? "",
          mediaType: media?.mediaType,
          posterURL: media?.posterURL,
          firstReleaseDate: media?.firstReleaseDate,
          match: matches[signal.id]
        )
      }
      let wrote = try await store.upsertSignals(rows, fetchedAt: clock())
      let mediaCount = Set(signals.map(\.mediaItemId)).count
      try await store.setState(
        .init(lastSuccessAt: clock(), lastStatus: "ok", lastError: nil,
              lastSignalCount: wrote, lastMediaCount: mediaCount),
        at: clock()
      )
      progress("外部热度", wrote)
      return PremiereBackfillSummary(fetched: signals.count, withDate: matchedCount, warning: nil)
    } catch {
      // 失败保留上次有效缓存（不写库不清行），状态如实记录；只计 warning
      let status: String
      if let whatsnewError = error as? WhatsNewClient.WhatsNewError,
         whatsnewError.message.contains("不是 WhatsNew 服务") {
        status = "bad_service"
      } else if error is DecodingError || "\(error)".contains("解析失败") {
        status = "invalid_response"
      } else {
        status = "unreachable"
      }
      let previousSuccess = (try? await store.state())?.lastSuccessAt
      try? await store.setState(
        .init(lastSuccessAt: previousSuccess, lastStatus: status,
              lastError: describe(error), lastSignalCount: nil, lastMediaCount: nil),
        at: clock()
      )
      return PremiereBackfillSummary(fetched: 0, withDate: 0,
                                     warning: "外部热度拉取失败（\(status)），下轮自动重试；不影响追剧与原同步")
    }
  }

  func describe(_ error: Error) -> String {
    if let parse = error as? ButaiParseError { return parse.message }
    if let db = error as? DatabaseError { return db.message }
    if let client = error as? ButaiClient.ClientError { return client.message }
    let ns = error as NSError
    return ns.localizedDescription
  }
}