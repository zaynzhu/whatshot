import Foundation

public struct UpcomingLocalization: Codable, Sendable, Equatable {
  public var tmdbID: Int?
  public var imdbID: String?
  public var chineseTitle: String?
}

extension TmdbClient {
  /// 唯一标题检索例外：美区电影，以原名、年份、导演互证，绝不取搜索第一项。
  func localizeUpcoming(_ row: UpcomingRelease) async throws -> UpcomingLocalization? {
    guard row.source == .whenToStream, row.kind == "movie", let title = row.originalTitle,
          let year = row.productionYear, let directors = row.directors, !directors.isEmpty else { return nil }
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "language", value: "en-US"),
      URLQueryItem(name: "include_adult", value: "false")]
    let (data, _) = try await get("/search/movie?" + (query.percentEncodedQuery ?? ""))
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pages = json["total_pages"] as? Int, pages <= 1,
          let candidates = json["results"] as? [[String: Any]] else { return nil }
    let exact = candidates.filter { Self.upcomingTitleMatches($0, title: title, year: year) }
    guard !exact.isEmpty, exact.count <= 3 else { return nil }
    var hits: [UpcomingLocalization] = []
    for candidate in exact {
      try Task.checkCancellation()
      guard let id = candidate["id"] as? Int, id > 0 else { continue }
      let (detailData, _) = try await get("/movie/\(id)?language=zh-CN&append_to_response=credits,translations")
      guard let detail = try JSONSerialization.jsonObject(with: detailData) as? [String: Any],
            detail["id"] as? Int == id,
            let original = detail["original_title"] as? String,
            Self.identityText(original) == Self.identityText(candidate["original_title"] as? String ?? ""),
            String((detail["release_date"] as? String ?? "").prefix(4)) == String(year),
            Self.upcomingDirectorsMatch(detail, names: directors) else { continue }
      let translations = (detail["translations"] as? [String: Any])?["translations"] as? [[String: Any]] ?? []
      let chinese = translations.filter { $0["iso_639_1"] as? String == "zh" }
        .sorted { ($0["iso_3166_1"] as? String == "CN" ? 0 : 1) < ($1["iso_3166_1"] as? String == "CN" ? 0 : 1) }
      let translated = chinese.compactMap { ($0["data"] as? [String: Any])?["title"] as? String }
        .first { WorkConnection.isChinese($0) }
      let imdb = detail["imdb_id"] as? String
      hits.append(UpcomingLocalization(tmdbID: id,
        imdbID: imdb.flatMap { $0.range(of: #"^tt[0-9]+$"#, options: .regularExpression) == nil ? nil : $0 },
        chineseTitle: translated.flatMap { WorkConnection.isChinese($0) ? $0 : nil }))
    }
    return hits.count == 1 ? hits[0] : nil
  }

  static func identityText(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: "’", with: "'")
  }

  static func upcomingTitleMatches(_ json: [String: Any], title: String, year: Int) -> Bool {
    guard String((json["release_date"] as? String ?? "").prefix(4)) == String(year) else { return false }
    return [json["title"], json["original_title"]].compactMap { $0 as? String }.contains { identityText($0) == identityText(title) }
  }

  static func upcomingDirectorsMatch(_ json: [String: Any], names: [String]) -> Bool {
    let credits = json["credits"] as? [String: Any]
    let crew = credits?["crew"] as? [[String: Any]] ?? []
    let actual = Set(crew.filter { $0["job"] as? String == "Director" }.compactMap { $0["name"] as? String }.map(identityText))
    return !actual.isEmpty && actual == Set(names.map(identityText))
  }
}

/// 每轮最多 10 部；未匹配缓存 7 天，已核验缓存 30 天，失败不覆盖上次结果。
public struct UpcomingLocalizationSync: Sendable {
  let store: WorkConnectionStore
  let client: TmdbClient
  public init(queue: DatabaseQueue, client: TmdbClient) {
    store = WorkConnectionStore(queue: queue)
    self.client = client
  }

  public func run(onProgress: @Sendable (String) async -> Void = { _ in }) async throws {
    let rows = try await store.activeReleases(sources: [.whenToStream])
    let cached = try await store.localizations()
    let now = Date()
    let candidates = rows.filter { row in
      guard row.originalTitle != nil, row.productionYear != nil, !(row.directors ?? []).isEmpty else { return false }
      guard let old = cached[row.id], old.fingerprint == row.identityFingerprint else { return true }
      let ttl: Double = old.value.chineseTitle == nil ? 7 * 86400 : 30 * 86400
      return now.timeIntervalSince(old.checkedAt) >= ttl
    }.sorted {
      let today = UpcomingDate.day(now, region: "US")
      let leftFuture = ($0.releaseDate ?? "") >= today
      let rightFuture = ($1.releaseDate ?? "") >= today
      if leftFuture != rightFuture { return leftFuture }
      return ($0.releaseDate ?? "", $0.id) < ($1.releaseDate ?? "", $1.id)
    }
    for (index, row) in candidates.prefix(10).enumerated() {
      try Task.checkCancellation()
      await onProgress("核对中文片名 · \(index + 1)/\(min(10, candidates.count))")
      let value = try await client.localizeUpcoming(row)
      try Task.checkCancellation()
      try await store.saveLocalization(value ?? UpcomingLocalization(), for: row, at: now)
    }
  }
}
