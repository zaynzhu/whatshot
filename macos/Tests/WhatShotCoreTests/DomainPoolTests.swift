import Foundation
import Testing
@testable import WhatShotCore

/// 域名池与择优器测试：候选组装、发布页自动发现解析、冠军快路径、故障降级
struct DomainPoolTests {
  /// 发布页 HOSTS 数组片段（2026-09-13 抓取的页面真实结构）
  static let publishPageSample = """
    <footer>…</footer>
    <script>
      const HOSTS = [
        "www.0bt0.com",
        "www.1bt0.com",
        "www.2bt0.com",
        "www.3bt0.com",
        "www.4bt0.com",
        "www.5bt0.com",
        "www.6bt0.com",
        "www.7bt0.com",
        "www.8bt0.com",
        "www.9bt0.com",
        "www.butai0.club",
        "www.butai0.com",
        "www.butai0.dev",
        "www.butai0.one",
        "www.butai0.vip",
        "www.butai0.xyz"
      ];
      const TIMEOUT_MS = 7000;
    </script>
  """

  /// 发布页解析：16 个域名全收、规范化补协议、保序
  @Test func parsePublishPageSample() {
    let domains = DomainPool.parsePublishPage(Self.publishPageSample)
    #expect(domains?.count == 16)
    #expect(domains?.first == "https://www.0bt0.com")
    #expect(domains?.last == "https://www.butai0.xyz")
    #expect(domains?.contains("https://www.butai0.dev") == true)
  }

  /// 发布页改版/缺 HOSTS/解析不出域名 → nil（调用方回落兜底池）
  @Test func parsePublishPageTolerance() {
    #expect(DomainPool.parsePublishPage("<html>无 HOSTS 的页面</html>") == nil)
    #expect(DomainPool.parsePublishPage("const HOSTS = []") == nil)
    // HOSTS 数组外出现统计脚本域名：不入池
    let polluted = """
      <script src="https://analytics.example.com/x.js"></script>
      const HOSTS = [ "www.butai0.club" ];
    """
    #expect(DomainPool.parsePublishPage(polluted) == ["https://www.butai0.club"])
    // 发布页自身域名出现在 HOSTS 里也不入池
    #expect(DomainPool.parsePublishPage(#"const HOSTS = [ "www.butailing.com", "www.butai0.club" ];"#)
            == ["https://www.butai0.club"])
  }

  /// 候选组装：自定义最高优先 + 发布页域在前 + 兜底池合入去重
  @Test func candidatesOrdering() {
    // 无发布页结果：自定义 + 兜底池
    let pool = DomainPool.candidates(customBaseURL: "www.9bt0.com/")
    #expect(pool.first == "https://www.9bt0.com")
    #expect(pool.count == 16) // 与兜底池重复去重后
    #expect(pool.contains("https://www.butai0.club"))

    // 自定义全新域名：17 个（1 自定义 + 16 兜底）
    let expanded = DomainPool.candidates(customBaseURL: "https://my-mirror.example")
    #expect(expanded.count == 17)
    #expect(expanded.first == "https://my-mirror.example")

    // 发布页发现新家族域名 butai0.new 冒在兜底池前、自定义仍最高
    let withPublished = DomainPool.candidates(
      customBaseURL: "https://my-mirror.example",
      published: ["https://www.butai0.new"]
    )
    #expect(withPublished.first == "https://my-mirror.example")
    #expect(withPublished[1] == "https://www.butai0.new")
    #expect(withPublished.count == 18)
  }

  /// 空自定义 + 无发布页 = 纯兜底池
  @Test func emptyCustomMeansOfficialOnly() {
    let pool = DomainPool.candidates(customBaseURL: "")
    #expect(pool == DomainPool.officialDomains)
    #expect(pool == DomainPool.fallbackDomains)
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
/// 钉住域名解码：旧配置文件（无 pinnedDomain 字段）兼容 + 新字段往返
@Test func pinnedDomainDecoding() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whatshot-settings-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  // 旧配置：无 pinnedDomain 字段
  let oldJSON = #"{"baseURL":"https://www.butai0.club","syncIntervalHours":6,"posterCacheLimitMB":300,"movieListPages":3,"tvListPages":3}"#
  try oldJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("settings.json"))
  let store = SettingsStore(directory: dir)
  let legacy = store.load()
  #expect(legacy.pinnedDomain == nil)
  #expect(legacy.baseURL == "https://www.butai0.club")

  // 新配置：钉住后往返不丢
  var pinned = legacy
  pinned.pinnedDomain = "https://www.3bt0.com"
  store.save(pinned)
  #expect(store.load().pinnedDomain == "https://www.3bt0.com")

  // 取消钉住（置 nil）往返
  pinned.pinnedDomain = nil
  store.save(pinned)
  #expect(store.load().pinnedDomain == nil)
}

/// 钉住探活：可达域名注入冠军；不可达返回 nil（调用方回落自动）
@Test func probePinnedBehavior() async {
  let selector = DomainSelector()
  let bad = await selector.probePinned("https://invalid.invalid.example", timeout: 0.5)
  #expect(bad == nil)
  #expect(await selector.currentDomain == nil)
}
