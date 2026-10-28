import Foundation
import CryptoKit

/// 公开排期只读客户端。各来源独立限频，完整翻页后才返回给存储层。
public struct UpcomingClient: Sendable {
  private let session: URLSession
  private let limiters: [UpcomingSource: RateLimiter]
  private let maxPages: Int
  private let userAgent = "Mozilla/5.0 WhatShot/1.0"
  private let mtopEndpoint = "https://acs.youku.com/h5/mtop.youku.columbus.gateway.new.execute/1.0/"
  private let appKey = "24679788"

  public init(session: URLSession? = nil, interval: TimeInterval = 2, maxPages: Int = 20) {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.urlCache = nil
    self.session = session ?? URLSession(configuration: config)
    self.limiters = Dictionary(uniqueKeysWithValues: UpcomingSource.allCases.map { ($0, RateLimiter(interval: interval)) })
    self.maxPages = maxPages
  }

  public func fetch(_ source: UpcomingSource) async throws -> [UpcomingRelease] {
    switch source {
    case .youku: return try await fetchYouku()
    case .iqiyi: return try await fetchIqiyi()
    case .tencent: return try await fetchTencent()
    }
  }

  private func request(_ url: URL, source: UpcomingSource, body: Data? = nil,
                       headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    await limiters[source]!.waitTurn()
    try Task.checkCancellation()
    var request = URLRequest(url: url, timeoutInterval: 25)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw UpcomingError("来源未返回 HTTP 响应") }
    guard (200..<300).contains(http.statusCode) else {
      throw UpcomingError("来源返回 HTTP \(http.statusCode)，稍后重试")
    }
    guard data.count <= 4_000_000 else { throw UpcomingError("来源响应过大，已停止解析") }
    return (data, http)
  }

  /// 相对日期只接受近期响应；没有 Date 头时用本机采集时刻。
  static func observationDate(_ response: HTTPURLResponse, now: Date = .now) throws -> Date {
    guard let text = response.value(forHTTPHeaderField: "Date") else { return now }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let value = formatter.date(from: text) else { return now }
    guard abs(value.timeIntervalSince(now)) < 900 else { throw UpcomingError("来源响应时间过旧，请稍后重新核实") }
    return value
  }

  // MARK: - 优酷匿名 MTop

  private func fetchYouku() async throws -> [UpcomingRelease] {
    var token: String?
    var cookies: String?
    var result: [String: UpcomingRelease] = [:]
    for (entityID, kind) in [(22861692, "movie"), (22916606, "series")] {
      var context: [String: Any]?
      var seenContexts = Set<String>()
      var completed = false
      for page in 1...maxPages {
        let data = try mtopData(entityID: entityID, page: page, context: context)
        var response: [String: Any]?
        var observedAt = Date()
        for attempt in 0...1 {
          if token == nil {
            let (_, http) = try await request(mtopURL(data: data, token: nil), source: .youku,
              headers: ["Referer": "https://www.youku.com/"])
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { values, item in
              if let key = item.key as? String { values[key] = String(describing: item.value) }
            }
            let pairs = HTTPCookie.cookies(withResponseHeaderFields: fields, for: URL(string: mtopEndpoint)!)
              .filter { ["_m_h5_tk", "_m_h5_tk_enc"].contains($0.name) }
            token = pairs.first { $0.name == "_m_h5_tk" }?.value.components(separatedBy: "_").first
            cookies = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard token?.isEmpty == false else { throw UpcomingError("优酷未返回匿名访问令牌") }
          }
          let (body, http) = try await request(mtopURL(data: data, token: token), source: .youku,
            headers: ["Referer": "https://www.youku.com/", "Cookie": cookies ?? ""])
          let json = try Self.object(body)
          let codes = json["ret"] as? [String] ?? []
          if codes.contains(where: { $0.hasPrefix("SUCCESS") }) {
            response = json
            observedAt = try Self.observationDate(http)
            break
          }
          if attempt == 0 && codes.contains(where: { $0.contains("TOKEN") }) { token = nil; continue }
          throw UpcomingError("优酷暂未允许读取待播节点，请稍后重试")
        }
        guard let response,
              let component = Self.findObjects(response, key: "typeName", value: "KU_FLIX_V_GRID_PIANDAN_COMPONENT").first,
              let nodes = component["nodes"] as? [[String: Any]],
              let more = component["more"] as? Bool else {
          throw UpcomingError("优酷预约节点结构变化")
        }
        let rows = try Self.parseYoukuNodes(nodes, kind: kind, observedAt: observedAt)
        for row in rows { result[row.id] = row }
        if !more { completed = true; break }
        guard !nodes.isEmpty, let next = (component["data"] as? [String: Any])?["session"] as? [String: Any],
              !next.isEmpty, seenContexts.insert(try Self.jsonText(next)).inserted else {
          throw UpcomingError("优酷分页不完整，已保留上次数据")
        }
        context = next
      }
      guard completed else { throw UpcomingError("优酷待播超过分页上限，未替换旧片单") }
    }
    guard !result.isEmpty else { throw UpcomingError("优酷未返回可验证的预约作品") }
    return Array(result.values)
  }

  private func mtopData(entityID: Int, page: Int, context: [String: Any]?) throws -> String {
    var params: [String: Any] = [
      "debug": 0, "utdid": "", "appPackageKey": "com.youku.pcweb", "ip": "127.0.0.1",
      "reqSubNode": 0, "gray": 0, "pageNo": page, "bizKey": "kuflix_node_page",
      "showNodeList": 0, "nodeKey": "PIANDAN_HEATLIST", "appKey": appKey,
      "bizContext": try Self.jsonText(["entityId": entityID, "entityType": "scg"])
    ]
    if let context { params["session"] = try Self.jsonText(context) }
    let system: [String: Any] = [
      "appPackageKey": "com.youku.pcweb", "device": "pcweb", "os": "pcweb", "ver": "1.0.0.0",
      "userAgent": userAgent, "guid": "1590141704165YXe", "young": 0, "brand": "", "network": "",
      "ouid": "", "idfa": "", "scale": "", "operator": "", "resolution": "", "pid": "",
      "childGender": 0, "zx": 0, "appkey": appKey
    ]
    return try Self.jsonText(["ms_codes": "2019041100", "params": Self.jsonText(params), "system_info": Self.jsonText(system)])
  }

  private func mtopURL(data: String, token: String?) throws -> URL {
    let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
    let sign = token.map {
      Insecure.MD5.hash(data: Data("\($0)&\(stamp)&\(appKey)&\(data)".utf8)).map { String(format: "%02x", $0) }.joined()
    } ?? ""
    var url = URLComponents(string: mtopEndpoint)!
    url.queryItems = ["jsv": "2.7.2", "appKey": appKey, "t": stamp, "sign": sign,
      "api": "mtop.youku.columbus.gateway.new.execute", "v": "1.0", "type": "originaljson",
      "dataType": "json", "data": data].map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let result = url.url else { throw UpcomingError("优酷请求构造失败") }
    return result
  }

  static func parseYoukuNodes(_ nodes: [[String: Any]], kind: String, observedAt: Date) throws -> [UpcomingRelease] {
    try nodes.compactMap { node in
      guard let data = node["data"] as? [String: Any] else { throw UpcomingError("优酷卡片数据缺失") }
      // 节点可能混入已播作品，预约结构是必要的待播证据。
      guard let reserve = data["reserve"] as? [String: Any] else { return nil }
      guard let action = data["action"] as? [String: Any], action["type"] as? String == "JUMP_TO_SHOW",
            let id = identity(action["value"]), let title = text(data["title"]),
            text(reserve["id"]) == nil || text(reserve["id"]) == id else {
        throw UpcomingError("优酷预约作品身份缺失")
      }
      let reason = (data["reason"] as? [String: Any])?["text"] as? [String: Any]
      let labels = (data["lbTexts"] as? [[String: Any]] ?? []).compactMap { text($0["title"]) }
      let raw = text(reason?["title"]) ?? labels.first(where: { $0.contains("上线") || $0.contains("期待") })
        ?? text(data["onlineDesc"]) ?? "敬请期待"
      let schedule = UpcomingDate.parse(raw, observedAt: observedAt)
      return UpcomingRelease(source: .youku, sourceID: id, kind: kind, title: title,
        posterURL: posterURL(data["img"], source: .youku),
        sourceURL: "https://www.youku.com/show_page/id_\(id).html",
        releaseDate: schedule.date, releaseTime: schedule.time, rawSchedule: raw, observedAt: observedAt)
    }
  }

  // MARK: - 爱奇艺只解码字面量

  private func fetchIqiyi() async throws -> [UpcomingRelease] {
    let (data, http) = try await request(URL(string: "https://www.iqiyi.com/newOnlinePCW")!, source: .iqiyi)
    guard let html = String(data: data, encoding: .utf8) else { throw UpcomingError("爱奇艺页面编码无效") }
    return try Self.parseIqiyi(html, observedAt: Self.observationDate(http))
  }

  static func parseIqiyi(_ html: String, observedAt: Date) throws -> [UpcomingRelease] {
    let payload = try NuxtLiteral.decode(html)
    guard let data = payload["data"] as? [[String: Any]], let videos = data.first?["allVideos"] as? [[String: Any]],
          !videos.isEmpty else { throw UpcomingError("爱奇艺未返回完整待播片单") }
    var result: [String: UpcomingRelease] = [:]
    for video in videos {
      // 页面另含综艺、少儿、纪录片等，缺少电影／剧集大类依据时不猜分类。
      guard let cid = (video["cid"] as? NSNumber)?.intValue, [1, 2].contains(cid) else { continue }
      guard let id = text(video["id"]), let title = text(video["name"]),
            let raw = text(video["publishText"]), let online = video["isOnline"] as? Bool else {
        throw UpcomingError("爱奇艺待播字段缺失，未替换旧片单")
      }
      // 未建详情页的预约仍有稳定 ID；原站入口回到真实片单，不伪造影片 URL。
      let url: String
      if text(video["pageUrl"]) == nil { url = "https://www.iqiyi.com/newOnlinePCW" }
      else if let detail = sourceURL(video["pageUrl"], hostSuffix: "iqiyi.com") { url = detail }
      else { throw UpcomingError("爱奇艺作品链接无效，未替换旧片单") }
      let schedule = UpcomingDate.parse(raw, observedAt: observedAt)
      let row = UpcomingRelease(source: .iqiyi, sourceID: id, kind: cid == 1 ? "movie" : "series", title: title,
        posterURL: posterURL(video["thumbnail"] ?? video["imageUrl"], source: .iqiyi), sourceURL: url,
        releaseDate: schedule.date, releaseTime: schedule.time, rawSchedule: raw,
        sourceReportsAvailable: online, observedAt: observedAt)
      result[row.id] = row
    }
    guard !result.isEmpty else { throw UpcomingError("爱奇艺片单缺少电影与剧集") }
    return Array(result.values)
  }

  // MARK: - 腾讯片库待播身份 + VIP 栏目独立排期

  private func fetchTencent() async throws -> [UpcomingRelease] {
    let url = URL(string: "https://pbaccess.video.qq.com/trpc.multi_vector_layout.mvl_controller.MVLPageHTTPService/getMVLPage?vversion_platform=2")!
    var result: [String: UpcomingRelease] = [:]
    for (channel, filter, kind) in [("100173", "999", "movie"), ("100113", "1", "series")] {
      var context: [String: Any]?
      var seenContexts = Set<String>()
      var completed = false
      for page in 1...maxPages {
        var body: [String: Any] = ["page_params": ["page_type": "operation", "page_id": "channel_list",
          "channel_id": channel, "filter_params": "iyear=\(filter)"]]
        if let context { body["page_context"] = context }
        let (data, http) = try await request(url, source: .tencent, body: JSONSerialization.data(withJSONObject: body),
          headers: ["Origin": "https://v.qq.com", "Referer": "https://v.qq.com/"])
        let response = try Self.object(data)
        guard (response["ret"] as? NSNumber)?.intValue == 0,
              let payload = response["data"] as? [String: Any], let modules = payload["modules"],
              let more = payload["has_next_page"] as? Bool else { throw UpcomingError("腾讯待播响应格式变化") }
        if page == 1 {
          let filters = Self.findObjects(modules, key: "type", value: "searchlist_filter_card")
          guard filters.contains(where: {
            guard let params = $0["params"] as? [String: Any] else { return false }
            return params["filter_key"] as? String == "iyear" && params["option_name"] as? String == "即将上线"
              && Self.text(params["option_value"]) == filter && Self.text(params["is_selected"]) == "1"
          }) else { throw UpcomingError("腾讯即将上线筛选契约变化") }
        }
        let cards = Self.findObjects(modules, key: "type", value: "searchlist_poster_card")
        guard !cards.isEmpty || (page > 1 && !more) else { throw UpcomingError("腾讯未返回待播作品") }
        let observedAt = try Self.observationDate(http)
        for card in cards {
          guard let params = card["params"] as? [String: Any] else { throw UpcomingError("腾讯卡片数据缺失") }
          let row = try Self.parseTencentCard(params, kind: kind, observedAt: observedAt)
          result[row.id] = row
        }
        if !more { completed = true; break }
        guard let next = payload["page_context"] as? [String: Any], !next.isEmpty,
              seenContexts.insert(try Self.jsonText(next)).inserted else { throw UpcomingError("腾讯分页不完整") }
        context = next
      }
      guard completed else { throw UpcomingError("腾讯待播超过分页上限，未替换旧片单") }
    }
    // 两个入口都成功后才交付快照；不能用缺少 VIP 的半份结果清掉旧排期。
    for row in try await fetchTencentVIP() {
      guard !result.values.contains(where: { $0.sourceID == row.sourceID && $0.kind != row.kind }) else {
        throw UpcomingError("腾讯同一作品的分类冲突，已保留上次数据")
      }
      result[row.id] = row
    }
    return Array(result.values)
  }

  private func fetchTencentVIP() async throws -> [UpcomingRelease] {
    var context = "new_marklabel=1"
    var seenContexts: Set<String> = [context]
    for _ in 1...maxPages {
      var url = URLComponents(string: "https://film.video.qq.com/x/autovue/film_index/cgi/getModList")!
      url.queryItems = [
        URLQueryItem(name: "_param", value: try Self.jsonText(["pageContext": context, "modNum": 5])),
        URLQueryItem(name: "env", value: "online"),
        URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
      ]
      let (data, http) = try await request(url.url!, source: .tencent,
        headers: ["Referer": "https://film.video.qq.com/"])
      let response = try Self.object(data)
      guard (response["code"] as? NSNumber)?.intValue == 0,
            let payload = response["data"] as? [String: Any],
            (payload["status"] as? NSNumber)?.intValue == 0,
            let modules = payload["modList"] as? [[String: Any]] else {
        throw UpcomingError("腾讯 VIP 栏目响应格式变化")
      }
      let upcoming = modules.filter {
        $0["type"] as? String == "type_58"
          && ($0["cms_data"] as? [String: Any])?["title"] as? String == "VIP即将上映"
      }
      if upcoming.count == 1, let module = upcoming.first {
        // 页面将整个栏目 list 交给横向列表，没有栏目内续页；首页其他推荐无需继续拉取。
        return try Self.parseTencentVIP(module, observedAt: Self.observationDate(http))
      }
      guard upcoming.isEmpty, !modules.isEmpty, let next = Self.text(payload["pageContext"]),
            !next.components(separatedBy: "&").contains("page=-1"),
            seenContexts.insert(next).inserted else {
        throw UpcomingError("腾讯 VIP 即将上映栏目缺失或分页不完整")
      }
      context = next
    }
    throw UpcomingError("腾讯 VIP 栏目超过分页上限，未替换旧片单")
  }

  static func parseTencentVIP(_ module: [String: Any], observedAt: Date) throws -> [UpcomingRelease] {
    guard module["type"] as? String == "type_58",
          (module["cms_data"] as? [String: Any])?["title"] as? String == "VIP即将上映",
          let items = module["list"] as? [[String: Any]], !items.isEmpty else {
      throw UpcomingError("腾讯 VIP 即将上映栏目结构变化")
    }
    var rows: [String: UpcomingRelease] = [:]
    for item in items {
      guard let card = item["cms_data"] as? [String: Any], let type = text(card["type"]) else {
        throw UpcomingError("腾讯 VIP 作品分类缺失")
      }
      // 腾讯 1=电影、2=电视剧；3=动漫、10=综艺，不根据标题猜测大类。
      guard ["1", "2"].contains(type) else { continue }
      guard let id = identity(card["cid"] ?? item["itemId"]),
            text(item["itemId"]) == nil || text(item["itemId"]) == id,
            let title = text(card["title"]), let raw = card["show_date"] as? String else {
        throw UpcomingError("腾讯 VIP 作品身份或排期字段缺失")
      }
      let schedule = try tencentVIPSchedule(raw, isText: text(card["data_type"]) == "text", observedAt: observedAt)
      let detail = sourceURL(card["web_url"], hostSuffix: "v.qq.com")
      let row = UpcomingRelease(source: .tencent, sourceID: id, kind: type == "1" ? "movie" : "series", title: title,
        posterURL: posterURL(card["image_url_vertical"], source: .tencent),
        sourceURL: detail ?? "https://film.video.qq.com/",
        releaseDate: schedule.date, releaseTime: schedule.time,
        rawSchedule: "VIP即将上映 · \(raw.isEmpty ? "敬请期待" : raw)", observedAt: observedAt)
      if let old = rows[id], old != row { throw UpcomingError("腾讯 VIP 同一作品出现冲突排期") }
      rows[id] = row
    }
    return Array(rows.values)
  }

  private static func tencentVIPSchedule(_ raw: String, isText: Bool, observedAt: Date) throws -> (date: String?, time: String?) {
    if isText || raw.isEmpty { return UpcomingDate.parse(raw, observedAt: observedAt) }
    // 结构化 show_date 是北京时间，严格校验，不能把无法解析的排期当成源已撤回。
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = UpcomingDate.calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
      throw UpcomingError("腾讯 VIP 排期格式变化")
    }
    // 腾讯前端将 23:59:59 显示为当日 24:00；统一为次日 00:00，保持相同语义。
    let value = raw.hasSuffix("23:59:59") ? date.addingTimeInterval(1) : date
    let parts = UpcomingDate.calendar.dateComponents([.hour, .minute], from: value)
    return (UpcomingDate.day(value), String(format: "%02d:%02d", parts.hour!, parts.minute!))
  }

  static func parseTencentCard(_ card: [String: Any], kind: String, observedAt: Date) throws -> UpcomingRelease {
    guard let id = identity(card["cid"]), let title = text(card["title"]) else { throw UpcomingError("腾讯作品身份缺失") }
    return UpcomingRelease(source: .tencent, sourceID: id, kind: kind, title: title,
      posterURL: posterURL(card["new_pic_vt"], source: .tencent), sourceURL: "https://v.qq.com/x/cover/\(id).html",
      releaseDate: nil, releaseTime: nil, rawSchedule: "即将上线 · 日期未公布", observedAt: observedAt)
  }

  // MARK: - 边界辅助

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpcomingError("来源响应不是对象") }
    return value
  }
  private static func jsonText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }
  private static func text(_ value: Any?) -> String? {
    let text = (value as? String) ?? (value as? NSNumber)?.stringValue
    return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
  private static func identity(_ value: Any?) -> String? {
    guard let value = text(value), value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
    return value
  }
  private static func findObjects(_ value: Any, key: String, value expected: String) -> [[String: Any]] {
    if let array = value as? [Any] { return array.flatMap { findObjects($0, key: key, value: expected) } }
    guard let object = value as? [String: Any] else { return [] }
    if object[key] as? String == expected { return [object] }
    return object.values.flatMap { findObjects($0, key: key, value: expected) }
  }
  private static func sourceURL(_ value: Any?, hostSuffix: String) -> String? {
    guard let raw = text(value), let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw),
          url.scheme == "https", url.user == nil, url.password == nil, let host = url.host,
          host == hostSuffix || host.hasSuffix("." + hostSuffix) else { return nil }
    return url.absoluteString
  }
  static func posterURL(_ value: Any?, source: UpcomingSource) -> String? {
    guard var raw = text(value) else { return nil }
    if raw.hasPrefix("//") { raw = "https:" + raw }
    guard var url = URLComponents(string: raw), let host = url.host else { return nil }
    if url.scheme == "http" {
      guard ["alicdn.com", "ykimg.com", "iqiyipic.com", "gtimg.cn", "gtimg.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
      }) else { return nil }
      url.scheme = "https"
    }
    guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }
    if source == .iqiyi && (host == "iqiyipic.com" || host.hasSuffix(".iqiyipic.com")) {
      url.path = url.path.replacingOccurrences(of: #"_(120_160|141_188)(\.[a-zA-Z]+)$"#,
        with: "_579_772$2", options: .regularExpression)
    }
    return url.url?.absoluteString
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
