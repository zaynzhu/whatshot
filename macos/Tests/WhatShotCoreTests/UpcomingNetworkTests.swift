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
}
