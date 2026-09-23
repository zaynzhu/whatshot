import Foundation

/// WhatsNew 外部热度（2026-09-22 可选接入）：用户自有 WhatsNew 服务的只读客户端。
/// 只读 health / trending / media detail 三个端点，独立 2 秒限频，任何失败不阻断主同步。
/// 不发送追剧清单或本地数据；地址不进日志。
public struct WhatsNewClient: Sendable {
  /// 归一化后的基址（去尾斜杠），如 http://192.168.1.10:19993
  public let baseURL: String
  private let limiter: RateLimiter
  private let session: URLSession

  public init(baseURL: String, limiter: RateLimiter = RateLimiter(interval: 2.0), session: URLSession = .shared) {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    self.baseURL = base
    self.limiter = limiter
    self.session = session
  }

  public struct WhatsNewError: Error {
    public let message: String
  }

  /// 服务身份验认：WhatsNew /api/health 返回固定 service 标识。
  /// HTML、错误服务或沙箱占位都不算成功——不能把错误服务当成功接入
  static let serviceIdentifier = "whatsnew-backend"

  // MARK: - 响应模型（保守解码：字段缺失不报错，宁缺勿错）

  /// GET /api/health
  public struct Health: Sendable, Equatable {
    public var ok: Bool
    public var service: String?
    public var environment: String?
  }

  /// trending 内嵌的作品标量字段（Prisma include 全标量，含 imdbId —— IMDb 直连匹配零额外请求）
  public struct MediaItem: Sendable, Equatable {
    public var id: String
    public var mediaType: String?
    public var releaseForm: String?
    public var titleDisplay: String
    public var titleChinese: String?
    public var titleOriginal: String?
    public var posterURL: String?
    public var firstReleaseDate: String?
    public var status: String?
    public var imdbId: String?
    public var tmdbId: Int?
    public var heatScore: Double?
  }

  /// 热度信号行（trending 响应条目）。capturedAt 保留站方 ISO 原文——
  /// 本地发现时间与站方采集时间分开，客户端成功取到的时间不冒充榜单更新时间
  public struct Signal: Sendable, Equatable {
    public var id: String
    public var mediaItemId: String
    public var source: String
    public var platform: String?
    public var region: String?
    public var window: String?
    public var rankingScope: String?
    public var rankingEntryKey: String?
    public var rankingEntryLabel: String?
    public var rank: Int?
    public var previousRank: Int?
    public var rankDelta: Int?
    public var valueLabel: String?
    public var capturedAt: String?
    public var isCurrent: Bool
    public var mediaItem: MediaItem?
  }

  /// GET /api/media/:id —— 身份与豆瓣评分独立缓存，不写主数据评分
  public struct MediaDetail: Sendable, Equatable, Codable {
    public var id: String
    public var imdbId: String?
    /// WhatsNew 无顶层 doubanId，豆瓣身份在 refs（source="douban"，sourceId="douban-<数字>"）
    public var sourceRefs: [SourceRef]
    public var doubanRating: DoubanRating? = nil

    public struct SourceRef: Sendable, Equatable, Codable {
      public var source: String
      public var sourceId: String
    }
  }

  public struct DoubanRating: Sendable, Equatable, Codable {
    public var value: Double
    public var voteCount: Int?
    public var capturedAt: String?
  }

  // MARK: - 请求

  private func get(_ path: String) async throws -> Data {
    guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
      throw WhatsNewError(message: "WhatsNew 服务地址无效：\(baseURL)")
    }
    await limiter.waitTurn()
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw WhatsNewError(message: "WhatsNew 响应不是 HTTP")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw WhatsNewError(message: "WhatsNew HTTP \(http.statusCode)")
    }
    return data
  }

  /// POST 请求（批量身份查询用）。4xx 时把服务端 error 码附进错误信息——
  /// invalid_body / batch_too_large / unsupported_contract_version / empty_lookup_batch 语义可辨
  private func post(_ path: String, body: Data) async throws -> Data {
    guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
      throw WhatsNewError(message: "WhatsNew 服务地址无效：\(baseURL)")
    }
    await limiter.waitTurn()
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw WhatsNewError(message: "WhatsNew 响应不是 HTTP")
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = String(decoding: data, as: UTF8.self).prefix(120)
      throw WhatsNewError(message: "WhatsNew HTTP \(http.statusCode): \(detail)")
    }
    return data
  }

  /// 健康检查：验证服务身份
  public func fetchHealth() async throws -> Health {
    let data = try await get("/api/health")
    let raw = try Self.decode(HealthPayload.self, from: data)
    guard raw.ok == true, raw.service == Self.serviceIdentifier else {
      throw WhatsNewError(message: "响应不是 WhatsNew 服务（service=\(raw.service ?? "未知")）")
    }
    return Health(ok: true, service: raw.service, environment: raw.environment)
  }

  /// 热门信号（无筛选 = 工作中心视图：按 heatScore 选最多 50 部活跃作品，返回其全部当前信号，
  /// 故信号条数可能大于 50；带信号级筛选改为最多 50 条匹配信号——两种截断都存在，
  /// 未出现的作品只能解释为"本次返回范围未覆盖"，不能解释为下榜）
  public func fetchTrending() async throws -> [Signal] {
    let data = try await get("/api/trending")
    let raw = try Self.decode(TrendingPayload.self, from: data)
    return (raw.items ?? []).compactMap(Self.parseSignal)
  }

  /// 详情（含 sourceRefs）。用于给 trending 未匹配条目补豆瓣身份。
  /// id 是 WhatsNew 内部 cuid，路径段只放行 cuid 字符集
  public func fetchMediaDetail(id: String) async throws -> MediaDetail {
    let allowed = id.allSatisfy { ($0.isLetter && $0.isASCII) || ($0.isNumber) || $0 == "-" }
    guard !id.isEmpty, allowed else {
      throw WhatsNewError(message: "media id 非法")
    }
    let data = try await get("/api/media/\(id)")
    let raw = try Self.decode(MediaDetailPayload.self, from: data)
    guard raw.id == id else {
      throw WhatsNewError(message: "WhatsNew 详情身份不一致")
    }
    return MediaDetail(
      id: raw.id ?? id,
      imdbId: raw.imdbId,
      sourceRefs: (raw.sourceRefs ?? []).compactMap { ref in
        guard let source = ref.source, let sourceId = ref.sourceId else { return nil }
        return .init(source: source, sourceId: sourceId)
      },
      doubanRating: raw.ratings?.compactMap(Self.parseDoubanRating).first
    )
  }

  // MARK: - 批量身份查询（契约 v1，2026-09-23）

  /// POST /api/media/lookup 响应行。query 字段按契约与输入位置对齐，消费方不读（忽略）。
  /// 三种"没有"分开：unmatched（reason）/ matched+signals 空（在库但无当前信号）/ 4xx 请求级错误
  public struct LookupItem: Sendable, Equatable {
    public var status: String
    public var reason: String?
    public var mediaId: String?
    public var matchBasis: String?
    public var matchLevel: String?
    public var titleDisplay: String?
    public var mediaType: String?
    public var firstReleaseDate: String?
    public var workStatus: String?
    public var heatScore: Double?
    public var signals: [Signal]
    public var lastSignalCapturedAt: String?
    public var doubanRating: DoubanRating?
    public var imdbId: String?
    public var tmdbId: Int?
    public var candidateMediaIds: [String]
  }

  public struct LookupResponse: Sendable, Equatable {
    public var contractVersion: Int?
    public var matched: Int
    public var unmatched: Int
    public var ambiguous: Int
    public var items: [LookupItem]
  }

  /// 批量身份查询：一次请求最多 50 个身份（douban + imdb 合计），客户端发送前自查
  /// 与服务端 400 batch_too_large 双保险；mediaType 大类隔离由服务端强制。
  /// 独立 2 秒限频（与 fetchTrending 共享同一 limiter）
  public func lookupMedia(mediaType: String, doubanIds: [Int], imdbIds: [String]) async throws -> LookupResponse {
    let total = doubanIds.count + imdbIds.count
    guard mediaType == "movie" || mediaType == "series" else {
      throw WhatsNewError(message: "lookup mediaType 必须为 movie 或 series")
    }
    guard total >= 1, total <= 50 else {
      throw WhatsNewError(message: "lookup 批量数须为 1–50（当前 \(total)）")
    }
    struct RequestBody: Encodable {
      var contractVersion: Int
      var mediaType: String
      var doubanIds: [Int]
      var imdbIds: [String]
    }
    let body = try JSONEncoder().encode(
      RequestBody(contractVersion: 1, mediaType: mediaType, doubanIds: doubanIds, imdbIds: imdbIds))
    let data = try await post("/api/media/lookup", body: body)
    return try Self.parseLookup(try Self.decode(LookupResponsePayload.self, from: data))
  }

  // MARK: - 解码（私有负载结构 → 容错映射为公开模型）

  struct HealthPayload: Decodable {
    var ok: Bool?
    var service: String?
    var environment: String?
  }

  struct TrendingPayload: Decodable {
    var items: [SignalPayload]?
  }

  /// 单条信号：身份三要素（id/mediaItemId/source）缺失即整行丢弃；
  /// 其余字段缺失按 nil 处理（接口解析容错，字段缺失不报错）
  struct SignalPayload: Decodable {
    var id: String?
    var mediaItemId: String?
    var source: String?
    var platform: String?
    var region: String?
    var window: String?
    var rankingScope: String?
    var rankingEntryKey: String?
    var rankingEntryLabel: String?
    var rank: Int?
    var previousRank: Int?
    var rankDelta: Int?
    var valueLabel: String?
    var capturedAt: String?
    var isCurrent: Bool?
    var mediaItem: MediaItemPayload?
  }

  struct MediaItemPayload: Decodable {
    var id: String?
    var mediaType: String?
    var releaseForm: String?
    var titleDisplay: String?
    var titleChinese: String?
    var titleOriginal: String?
    var posterUrl: String?
    var firstReleaseDate: String?
    var status: String?
    var imdbId: String?
    var tmdbId: Int?
    var heatScore: Double?
  }

  struct MediaDetailPayload: Decodable {
    var id: String?
    var imdbId: String?
    var sourceRefs: [SourceRefPayload]?
    var ratings: [RatingPayload]?

    struct SourceRefPayload: Decodable {
      var source: String?
      var sourceId: String?
    }
  }

  struct RatingPayload: Decodable {
    var source: String?
    var audience: String?
    var value: Double?
    var scale: Int?
    var voteCount: Int?
    var capturedAt: String?
  }

  static func parseDoubanRating(_ rating: RatingPayload) -> DoubanRating? {
    guard rating.source == "douban", rating.audience == "users", rating.scale == 10,
          let value = rating.value, value.isFinite, (0...10).contains(value) else { return nil }
    return DoubanRating(value: value,
                        voteCount: rating.voteCount.flatMap { $0 >= 0 ? $0 : nil },
                        capturedAt: rating.capturedAt)
  }

  private static func parseSignal(_ item: SignalPayload) -> Signal? {
    guard let id = item.id, let mediaItemId = item.mediaItemId, let source = item.source else {
      return nil
    }
    let media = item.mediaItem.map { media in
      MediaItem(
        id: media.id ?? mediaItemId,
        mediaType: media.mediaType,
        releaseForm: media.releaseForm,
        titleDisplay: media.titleDisplay ?? "",
        titleChinese: media.titleChinese,
        titleOriginal: media.titleOriginal,
        posterURL: media.posterUrl,
        firstReleaseDate: media.firstReleaseDate,
        status: media.status,
        imdbId: media.imdbId,
        tmdbId: media.tmdbId,
        heatScore: media.heatScore
      )
    }
    return Signal(
      id: id, mediaItemId: mediaItemId, source: source,
      platform: item.platform, region: item.region, window: item.window,
      rankingScope: item.rankingScope, rankingEntryKey: item.rankingEntryKey,
      rankingEntryLabel: item.rankingEntryLabel,
      rank: item.rank, previousRank: item.previousRank, rankDelta: item.rankDelta,
      valueLabel: item.valueLabel, capturedAt: item.capturedAt,
      isCurrent: item.isCurrent ?? true,
      mediaItem: media
    )
  }

  struct LookupResponsePayload: Decodable {
    var contractVersion: Int?
    var counts: CountsPayload?
    var items: [LookupItemPayload]?

    struct CountsPayload: Decodable {
      var matched: Int?
      var unmatched: Int?
      var ambiguous: Int?
    }
  }

  struct LookupItemPayload: Decodable {
    var status: String?
    var reason: String?
    var mediaId: String?
    var matchBasis: String?
    var matchLevel: String?
    var titleDisplay: String?
    var mediaType: String?
    var firstReleaseDate: String?
    var workStatus: String?
    var heatScore: Double?
    var signals: [SignalPayload]?
    var lastSignalCapturedAt: String?
    var doubanRating: DoubanRatingPayload?
    var imdbId: String?
    var tmdbId: Int?
    var candidateMediaIds: [String]?
  }

  struct DoubanRatingPayload: Decodable {
    var value: Double?
    var scale: Int?
    var voteCount: Int?
    var capturedAt: String?
  }

  static func parseLookup(_ raw: LookupResponsePayload) -> LookupResponse {
    let items = (raw.items ?? []).compactMap { item -> LookupItem? in
      guard let status = item.status else { return nil } // status 缺失的行无法解释，丢弃
      return LookupItem(
        status: status,
        reason: item.reason,
        mediaId: item.mediaId,
        matchBasis: item.matchBasis,
        matchLevel: item.matchLevel,
        titleDisplay: item.titleDisplay,
        mediaType: item.mediaType,
        firstReleaseDate: item.firstReleaseDate,
        workStatus: item.workStatus,
        heatScore: item.heatScore,
        signals: (item.signals ?? []).compactMap(parseSignal),
        lastSignalCapturedAt: item.lastSignalCapturedAt,
        doubanRating: item.doubanRating.flatMap(Self.parseDoubanRating),
        imdbId: item.imdbId,
        tmdbId: item.tmdbId,
        candidateMediaIds: item.candidateMediaIds ?? []
      )
    }
    return LookupResponse(
      contractVersion: raw.contractVersion,
      matched: raw.counts?.matched ?? items.filter { $0.status == "matched" }.count,
      unmatched: raw.counts?.unmatched ?? items.filter { $0.status == "unmatched" }.count,
      ambiguous: raw.counts?.ambiguous ?? items.filter { $0.status == "ambiguous" }.count,
      items: items
    )
  }

  /// lookup 响应的 doubanRating 单值对象（value/scale/voteCount/capturedAt）。
  /// scale 存在且非 10 的行不采信（契约口径 scale=10）
  static func parseDoubanRating(_ payload: DoubanRatingPayload) -> DoubanRating? {
    guard let value = payload.value, value.isFinite, (0...10).contains(value),
          payload.scale == nil || payload.scale == 10 else { return nil }
    return DoubanRating(value: value,
                        voteCount: payload.voteCount.flatMap { $0 >= 0 ? $0 : nil },
                        capturedAt: payload.capturedAt)
  }

  /// 基础 JSON 校验 + 解码。字段名对不上/类型不符按 nil 处理（全 Optional），
  /// 只有非 JSON 才报错——由调用方按步容错
  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw WhatsNewError(message: "WhatsNew 响应解析失败（非 JSON 或结构不符）")
    }
  }
}

// MARK: - 身份匹配（纯函数，可测试）

/// WhatsNew 信号 ↔ WhatShot 本地条目的匹配规则（2026-09-22 定案口径）：
/// 只做稳定 ID 精确相等匹配，不做标题相似度、不做系列→季推断；
/// 电影/剧集绝不互配；双 ID 指向不同本地条目 = ambiguous 不擅自选；
/// 匹配不上的显示"未关联"，保留外部榜单条目
public enum ExternalHeatMatcher {
  /// 本地库内身份（点查缓存）
  public struct LocalIdentity: Sendable, Equatable {
    public var id: Int
    public var kind: ButaiKind
    public var imdbNumber: String?
    public var doubanId: Int?

    public init(id: Int, kind: ButaiKind, imdbNumber: String?, doubanId: Int?) {
      self.id = id
      self.kind = kind
      self.imdbNumber = imdbNumber
      self.doubanId = doubanId
    }
  }

  /// 匹配依据：imdb（tt 号精确相等）/ douban（豆瓣 subject 数字精确相等）
  public enum Basis: String, Sendable, Equatable {
    case imdb
    case douban
  }

  /// 匹配结果：videoID = 本地条目；basis = 匹配依据
  public struct Match: Sendable, Equatable {
    public var videoID: Int
    public var basis: Basis

    public init(videoID: Int, basis: Basis) {
      self.videoID = videoID
      self.basis = basis
    }
  }

  /// 提取 WhatsNew sourceRefs 里的豆瓣 subject 数字（source="douban"，sourceId="douban-<数字>"）
  public static func doubanIds(in refs: [WhatsNewClient.MediaDetail.SourceRef]) -> [Int] {
    refs.compactMap { ref in
      guard ref.source == "douban" else { return nil }
      guard let digits = ref.sourceId.split(separator: "-", omittingEmptySubsequences: false)
        .last, let id = Int(digits), id > 0 else { return nil }
      return id
    }
  }

  /// mediaType ↔ kind 隔离：WhatsNew "movie"↔电影、"series"↔剧集；
  /// 其他取值（WhatsNew 未来扩展）保守不匹配
  static func kindCompatible(mediaType: String?, kind: ButaiKind) -> Bool {
    switch (mediaType?.lowercased(), kind) {
    case ("movie", .movie), ("series", .tvSeries):
      return true
    default:
      return false
    }
  }

  /// IMDb 号规范化：trim + 小写（tt 前缀统一小写比较）
  public static func normalizedIMDb(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// 对一个 WhatsNew 作品（mediaItem）做匹配。mediaIMDb 为空或 mediaType 不识别时返回 nil。
  /// doubanRefs 为空 = 该作品豆瓣身份未取到（detail 未查或无 douban ref）。
  /// 双 ID 分别命中不同本地条目 → 冲突，返回 nil（不擅自选）
  public static func match(mediaIMDb: String?, mediaType: String?, doubanRefs: [Int],
                           local: [LocalIdentity]) -> Match? {
    let normalized = mediaIMDb.map(normalizedIMDb) ?? ""
    let imdbHit: LocalIdentity? = normalized.hasPrefix("tt")
      ? local.first { kindCompatible(mediaType: mediaType, kind: $0.kind)
          && $0.imdbNumber.map { normalizedIMDb($0) } == normalized }
      : nil
    let doubanHit: LocalIdentity? = doubanRefs.compactMap { doubanId in
      local.first { kindCompatible(mediaType: mediaType, kind: $0.kind) && $0.doubanId == doubanId }
    }.first

    switch (imdbHit, doubanHit) {
    case let (imdb?, douban?):
      // 双 ID 命中同一本地条目：互证，按 imdb 记依据；指向不同条目 → 冲突不匹配
      return imdb.id == douban.id ? Match(videoID: imdb.id, basis: .imdb) : nil
    case let (imdb?, nil):
      return Match(videoID: imdb.id, basis: .imdb)
    case let (nil, douban?):
      return Match(videoID: douban.id, basis: .douban)
    case (nil, nil):
      return nil
    }
  }
}