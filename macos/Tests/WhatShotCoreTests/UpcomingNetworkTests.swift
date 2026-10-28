import Foundation
import Testing
@testable import WhatShotCore

@Suite(.serialized)
struct UpcomingNetworkTests {
  final class Stub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var respond: (URLRequest, Int) throws -> (Int, [String: String], String) = { _, _ in (500, [:], "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      Self.requests.append(request)
      do {
        let (status, headers, body) = try Self.respond(request, Self.requests.count)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
      } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
  }

  private func client(maxPages: Int = 20) -> UpcomingClient {
    Stub.requests = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    config.httpShouldSetCookies = false
    return UpcomingClient(session: URLSession(configuration: config), interval: 0, maxPages: maxPages)
  }
  private func youku(more: Bool, context: Bool = true) -> String {
    """
    {"ret":["SUCCESS::调用成功"],"data":{"typeName":"KU_FLIX_V_GRID_PIANDAN_COMPONENT","more":\(more),
    "data":\(context ? "{\"session\":{\"cursor\":\"same\"}}" : "{}"),"nodes":[{"data":{"title":"预约作品",
    "reserve":{"id":"abc"},"action":{"type":"JUMP_TO_SHOW","value":"abc"},"onlineDesc":"明天16:00上线"}}]}}
    """
  }

  @Test func anonymousHandshakeAndCompleteBothCategories() async throws {
    let client = client()
    let payload = youku(more: false)
    Stub.respond = { request, count in
      if count == 1 {
        return (200, ["Set-Cookie": "_m_h5_tk=testtoken_999999; Path=/; Secure"], "{}")
      }
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("testtoken") == true)
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(query.first { $0.name == "sign" }?.value?.count == 32)
      return (200, [:], payload)
    }
    let rows = try await client.fetch(.youku)
    #expect(Set(rows.map(\.kind)) == ["movie", "series"])
    #expect(rows.allSatisfy { $0.releaseTime == "16:00" })
    #expect(Stub.requests.count == 3)
  }

  @Test func incompleteAndRepeatedPaginationNeverReturnsPartialSnapshot() async {
    for context in [false, true] {
      let client = client()
      let payload = youku(more: true, context: context)
      Stub.respond = { _, count in
        count == 1 ? (200, ["Set-Cookie": "_m_h5_tk=token_999; Path=/"], "{}") : (200, [:], payload)
      }
      await #expect(throws: UpcomingError.self) { try await client.fetch(.youku) }
      #expect(Stub.requests.count == (context ? 3 : 2))
    }
    let client = client(maxPages: 1)
    let payload = youku(more: true)
    Stub.respond = { _, count in
      count == 1 ? (200, ["Set-Cookie": "_m_h5_tk=token_999; Path=/"], "{}") : (200, [:], payload)
    }
    await #expect(throws: UpcomingError.self) { try await client.fetch(.youku) }
  }

  @Test func tokenRetryIsBoundedAndHTTPFailureDoesNotRetry() async {
    let client = client()
    Stub.respond = { _, count in
      count % 2 == 1 ? (200, ["Set-Cookie": "_m_h5_tk=token_999; Path=/"], "{}")
        : (200, [:], #"{"ret":["FAIL_SYS_TOKEN_EXPIRED"]}"#)
    }
    await #expect(throws: UpcomingError.self) { try await client.fetch(.youku) }
    #expect(Stub.requests.count == 4)
    Stub.requests = []
    Stub.respond = { _, _ in (429, [:], "") }
    await #expect(throws: UpcomingError.self) { try await client.fetch(.youku) }
    #expect(Stub.requests.count == 1)
  }

  @Test func tencentRejectsUnverifiedFilter() async {
    let client = client()
    Stub.respond = { _, _ in
      (200, [:], #"{"ret":0,"data":{"has_next_page":false,"modules":[{"type":"searchlist_poster_card","params":{"cid":"abc","title":"不能确定待播"}}]}}"#)
    }
    await #expect(throws: UpcomingError.self) { try await client.fetch(.tencent) }
    #expect(Stub.requests.count == 1)
  }

  private func tencentCatalog(filter: String, cid: String) -> String {
    """
    {"ret":0,"data":{"has_next_page":false,"modules":[
    {"type":"searchlist_filter_card","params":{"filter_key":"iyear","option_name":"即将上线","option_value":"\(filter)","is_selected":"1"}},
    {"type":"searchlist_poster_card","params":{"cid":"\(cid)","title":"同名作品","publish_date":"2026-01-01"}}]}}
    """
  }

  private func vipPage(schedule: String = "2026-10-30 10:00:00", dataType: String = "") -> String {
    """
    {"code":0,"data":{"status":0,"pageContext":"page=2","modList":[
    {"type":"type_58","cms_data":{"title":"VIP即将上映"},"list":[
    {"itemId":"movie","cms_data":{"cid":"movie","title":"同名作品","type":"1","show_date":"\(schedule)","data_type":"\(dataType)","web_url":"https://v.qq.com/x/cover/movie.html"}},
    {"itemId":"other","cms_data":{"cid":"other","title":"同名作品","type":"1","show_date":"敬请期待","data_type":"text"}},
    {"itemId":"vipOnly","cms_data":{"cid":"vipOnly","title":"栏目独有","type":"2","show_date":"2026-10-29 12:00:00"}},
    {"itemId":"variety","cms_data":{"cid":"variety","title":"综艺","type":"10","show_date":"2026-10-30 10:00:00"}},
    {"itemId":"anime","cms_data":{"cid":"anime","title":"动漫","type":"3","show_date":"敬请期待","data_type":"text"}}
    ]}]}}
    """
  }

  @Test func tencentVIPMergesByIDAndWithdrawsSchedule() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    let now = ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z")!
    for withdraw in [false, true] {
      let client = client()
      let movie = tencentCatalog(filter: "999", cid: "movie")
      let series = tencentCatalog(filter: "1", cid: "series")
      let vip = withdraw ? vipPage(schedule: "敬请期待", dataType: "text") : vipPage()
      Stub.respond = { request, count in
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        if count <= 2 { return (200, [:], count == 1 ? movie : series) }
        #expect(request.url?.host == "film.video.qq.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let param = query.first { $0.name == "_param" }!.value!
        #expect(param.contains(count == 3 ? "new_marklabel=1" : "page=1"))
        return (200, [:], count == 3
          ? #"{"code":0,"data":{"status":0,"pageContext":"page=1","modList":[{"type":"placeholder"}]}}"# : vip)
      }
      let rows = try await client.fetch(.tencent)
      #expect(rows.count == 4)
      #expect(rows.filter { $0.sourceID == "movie" }.count == 1)
      #expect(rows.first { $0.sourceID == "movie" }?.releaseTime == (withdraw ? nil : "10:00"))
      #expect(rows.first { $0.sourceID == "other" }?.releaseDate == nil)
      #expect(rows.first { $0.sourceID == "series" }?.releaseDate == nil)
      #expect(rows.first { $0.sourceID == "vipOnly" }?.releaseTime == "12:00")
      #expect(Stub.requests.count == 4)
      try await store.replace(rows, source: .tencent, at: now)
      #expect(try await store.releases(sources: [.tencent], now: now).contains { $0.sourceID == "movie" } == !withdraw)
    }
  }

  @Test func tencentVIPFailureCannotPublishPartialCatalog() async {
    let movie = tencentCatalog(filter: "999", cid: "movie")
    let series = tencentCatalog(filter: "1", cid: "series")
    let badPages = [
      #"{"code":0,"data":{"status":0,"pageContext":"page=-1","modList":[]}}"#,
      #"{"code":0,"data":{"status":0,"pageContext":"new_marklabel=1","modList":[{"type":"placeholder"}]}}"#,
      vipPage(schedule: "2026-02-30 10:00:00"),
      vipPage().replacingOccurrences(of: "\"cid\":\"movie\"", with: "\"cid\":\"wrong\"")
    ]
    for bad in badPages {
      let client = client()
      Stub.respond = { _, count in (200, [:], count == 1 ? movie : count == 2 ? series : bad) }
      await #expect(throws: UpcomingError.self) { try await client.fetch(.tencent) }
      #expect(Stub.requests.count == 3)
    }
    let client = client(maxPages: 1)
    Stub.respond = { _, count in
      (200, [:], count == 1 ? movie : count == 2 ? series
        : #"{"code":0,"data":{"status":0,"pageContext":"page=1","modList":[{"type":"placeholder"}]}}"#)
    }
    await #expect(throws: UpcomingError.self) { try await client.fetch(.tencent) }
    #expect(Stub.requests.count == 3)
  }

  @Test func tencentVIPPreservesPrecisionAndMidnightMeaning() throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z")!
    for (raw, type, date, time) in [
      ("2026-12-31 23:59:59", "", "2027-01-01", "00:00" as String?),
      ("2026-10-30 00:00:00", "", "2026-10-30", "00:00"),
      ("2026-10-30", "text", "2026-10-30", nil),
      ("后天 10:00 上线", "text", "2026-10-30", "10:00")
    ] {
      let response = try JSONSerialization.jsonObject(with: Data(vipPage(schedule: raw, dataType: type).utf8)) as! [String: Any]
      let module = ((response["data"] as! [String: Any])["modList"] as! [[String: Any]])[0]
      let rows = try UpcomingClient.parseTencentVIP(module, observedAt: now)
      let row = rows.first { $0.sourceID == "movie" }
      #expect(row?.releaseDate == date)
      #expect(row?.releaseTime == time)
    }
  }
}
