import Foundation
import Testing
@testable import WhatShotCore

struct UpcomingGroupingTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z")!

  func row(_ source: UpcomingSource, _ id: String, _ title: String, date: String? = nil,
           time: String? = nil, kind: String = "movie") -> UpcomingRelease {
    UpcomingRelease(source: source, sourceID: id, kind: kind, title: title,
      sourceURL: "https://example.com/\(id)", releaseDate: date, releaseTime: time,
      rawSchedule: "来源原文", observedAt: now)
  }

  @Test func combinesPlatformsWithoutBorrowingDatesOrSplittingAcrossWindows() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    try await store.replace([row(.youku, "a", "玩具总动员5", date: "2026-10-30", time: "10:00")], source: .youku, at: now)
    try await store.replace([row(.iqiyi, "b", "玩具总动员5", date: "2026-10-31")], source: .iqiyi, at: now)
    try await store.replace([row(.tencent, "c", "玩具总动员5")], source: .tencent, at: now)
    let works = try await store.works(sources: UpcomingSource.allCases, now: now)
    #expect(works.count == 1)
    #expect(works.first?.releaseDate == "2026-10-30")
    #expect(works.first?.releases.map(\.source) == [.youku, .iqiyi, .tencent])
    #expect(works.first?.releases.map(\.releaseTime) == ["10:00", nil, nil])
    #expect(works.first?.releases.map(\.releaseDate) == ["2026-10-30", "2026-10-31", nil])
    #expect(try await store.works(sources: UpcomingSource.allCases, window: .undated, now: now).isEmpty)
    #expect(try await store.works(sources: [.tencent], window: .undated, now: now).first?.releases.count == 1)
    // 最近一次排期归入近期，不把仍未定档的平台单独拆回待定档。
    let later = now.addingTimeInterval(4 * 86400)
    #expect(try await store.works(sources: UpcomingSource.allCases, window: .recent, now: later).first?.releaseDate == "2026-10-31")
  }

  @Test func paginationCountsWorksAndPreservesSeasonsKindsAndAmbiguity() async throws {
    let store = UpcomingStore(queue: try DatabaseQueue(path: ":memory:"))
    let titles = (0..<65).map { "电影\(String(format: "%03d", $0))" }
    try await store.replace(titles.enumerated().map { row(.youku, "y\($0.offset)", $0.element) }, source: .youku, at: now)
    try await store.replace(titles.enumerated().map { row(.iqiyi, "i\($0.offset)", $0.element) }, source: .iqiyi, at: now)
    let first = try await store.works(sources: [.youku, .iqiyi], window: .undated, now: now)
    let second = try await store.works(sources: [.youku, .iqiyi], window: .undated, now: now, offset: 60)
    #expect(first.count == 60)
    #expect(second.count == 5)
    #expect(first.allSatisfy { $0.releases.count == 2 })
    #expect(Set((first + second).map(\.id)).count == 65)
    try await store.replace([
      row(.youku, "1", "同名"), row(.youku, "2", "同名"),
      row(.youku, "3", "同名", kind: "series"), row(.youku, "4", "同名 第二季", kind: "series")
    ], source: .youku, at: now)
    try await store.replace([row(.iqiyi, "1", "同名")], source: .iqiyi, at: now)
    let ambiguous = try await store.works(sources: [.youku, .iqiyi], window: .undated, now: now)
    #expect(ambiguous.count == 5)
    #expect(ambiguous.allSatisfy { $0.releases.count == 1 })
  }
}
