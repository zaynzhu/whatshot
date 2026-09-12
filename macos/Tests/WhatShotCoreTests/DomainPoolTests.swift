import Foundation
import Testing
@testable import WhatShotCore

/// 域名池与择优器测试：候选组装、冠军快路径、故障降级
struct DomainPoolTests {
  /// 自定义地址最高优先 + 去重 + 协议补全
  @Test func candidatesOrdering() {
    let pool = DomainPool.candidates(customBaseURL: "www.9bt0.com/")
    // www.9bt0.com 与官方池重复，去重后仍是 12 个
    #expect(pool.first == "https://www.9bt0.com")
    #expect(pool.count == 12)
    #expect(pool.contains("https://www.butai0.club"))
    // 自定义全新域名时为 13 个（1 自定义 + 12 官方）
    let expanded = DomainPool.candidates(customBaseURL: "https://my-mirror.example")
    #expect(expanded.count == 13)
    #expect(expanded.first == "https://my-mirror.example")
  }

  /// 空自定义 = 纯官方池
  @Test func emptyCustomMeansOfficialOnly() {
    let pool = DomainPool.candidates(customBaseURL: "")
    #expect(pool == DomainPool.officialDomains)
  }

  /// 规范化：协议补全、末尾斜杠、空白
  @Test func normalization() {
    #expect(DomainPool.normalized("  butai0.club  ") == "https://butai0.club")
    #expect(DomainPool.normalized("https://www.butai0.club///") == "https://www.butai0.club")
    #expect(DomainPool.normalized("") == nil)
  }

  /// 探活器对全失败域名池返回 nil（不可达域名不产生冠军）
  @Test func pickBestAllFail() async {
    let selector = DomainSelector()
    let probe = await selector.pickBest(
      candidates: ["https://invalid.invalid.example"],
      timeout: 0.5
    )
    #expect(probe == nil)
    #expect(await selector.currentDomain == nil)
  }
}