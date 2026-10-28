import Foundation
import Testing
@testable import WhatShotCore

@Suite(.serialized)
struct UpcomingLocalizationTests {
  final class Stub: URLProtocol {
    nonisolated(unsafe) static var search: [String: Any] = [:]
    nonisolated(unsafe) static var details: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let path = request.url!.path
      Self.requests.append(path)
      let object = path.hasSuffix("/search/movie") ? Self.search : Self.details[path] ?? [:]
      let data = try! JSONSerialization.data(withJSONObject: object)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  func client() -> TmdbClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    Stub.requests = []
    return TmdbClient(apiKey: "test", limiter: RateLimiter(interval: 0), session: URLSession(configuration: config))
  }

  func candidate(_ id: Int = 12, year: Int = 2026) -> [String: Any] {
    ["id": id, "title": "Same Name", "original_title": "Same Name", "release_date": "\(year)-01-01"]
  }

  func detail(_ id: Int = 12, director: String = "Jane Doe", title: String = "已核实中文名") -> [String: Any] {
    ["id": id, "title": title, "original_title": "Same Name", "release_date": "2026-01-01", "imdb_id": "tt123",
     "credits": ["crew": [["job": "Director", "name": director]]],
     "translations": ["translations": [["iso_639_1": "zh", "iso_3166_1": "CN", "data": ["title": title]]]]]
  }

  @Test func requiresExactTitleYearDirectorAndUniqueIdentity() async throws {
    let row = WorkConnectionTests().release(.whenToStream)
    Stub.search = ["total_pages": 1, "results": [candidate()]]
    Stub.details = ["/3/movie/12": detail()]
    let result = try await client().localizeUpcoming(row)
    #expect(result?.chineseTitle == "已核实中文名" && result?.imdbID == "tt123")
    Stub.details = ["/3/movie/12": detail(director: "Someone Else")]
    #expect(try await client().localizeUpcoming(row) == nil)
    Stub.search = ["total_pages": 1, "results": [candidate(year: 1990)]]
    #expect(try await client().localizeUpcoming(row) == nil)
    #expect(Stub.requests.count == 1)
    Stub.search = ["total_pages": 1, "results": [candidate(), candidate(13)]]
    Stub.details = ["/3/movie/12": detail(), "/3/movie/13": detail(13)]
    #expect(try await client().localizeUpcoming(row) == nil)
    Stub.search = ["total_pages": 2, "results": [candidate()]]
    #expect(try await client().localizeUpcoming(row) == nil)
    var missing = row
    missing.directors = nil
    #expect(try await client().localizeUpcoming(missing) == nil)
    #expect(Stub.requests.isEmpty)
  }

  @Test func preservesOriginalWhenNoChineseAndParsesIdentityEvidence() async throws {
    let row = WorkConnectionTests().release(.whenToStream)
    Stub.search = ["total_pages": 1, "results": [candidate()]]
    Stub.details = ["/3/movie/12": detail(title: "Same Name")]
    let result = try await client().localizeUpcoming(row)
    #expect(result?.chineseTitle == nil && result?.tmdbID == 12)
    let page = OverseasDigitalTests.page(title: "Same Name (2026)", html: "<p><strong>Director</strong>: Jane Doe</p><p>VOD Release Date: November 3, 2026</p>")
    let candidate = OverseasDigitalParser.Candidate(slug: "primetime-2026", url: "https://whentostream.com/primetime-2026/", date: "2026-11-03", poster: nil)
    let parsed = try OverseasDigitalParser.release(page, candidate: candidate, observedAt: .now)
    #expect(parsed.originalTitle == "Same Name" && parsed.productionYear == 2026)
    #expect(parsed.directors == ["Jane Doe"])
    #expect(parsed.title == "Same Name (2026)" && parsed.releaseTime == nil)
  }
}
