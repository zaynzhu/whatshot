# Swift Testing 并行测试与 stub 状态隔离

结论速览：
- **方案**：URLProtocol stub（或任何 static 状态）做集成测试时，套件声明 `@Suite(.serialized)`——Swift Testing 默认**并行**执行，测试间共享 static 状态会交叉污染，且失败表现极具迷惑性（断言失败落在与污染源无关的测试上）。
- **适用**：macOS / Swift 6 工具链 / swift-testing；URLProtocol stub + 共享 static routes 的集成测试模式。

## ✅ URLProtocol stub 共享 static 状态在并行测试下交叉污染（2026-09-22）

- **为何值得记**：4 项引擎集成测试初跑 4 失败，现象（请求路径重复出现、A 测试拿到 B 测试注入的响应）与真实根因（并行）完全对不上，误判为"匹配逻辑失败"排查了一轮。
- **最终方案**：
  ```swift
  @Suite(.serialized)
  @MainActor
  struct WhatsNewEngineTests {
    final class StubProtocol: URLProtocol, @unchecked Sendable {
      nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
      ...
    }
  }
  ```
  每个测试开头 `reset()` 清空 static 路由与请求记录。
- **为什么这样做**：Swift Testing 默认多测试并行；static 字典跨测试共享 → 测试 A 注入的 stub 被 B 读到、requestedPaths 混入所有测试的请求。`@Suite(.serialized)` 串行化后，reset() 按测试隔离状态即可稳定。
- **适用条件**：Swift Testing（swift test）；XCTest 的默认执行模型不同（XCTest 默认串行），此坑为 Swift Testing 特有。
- **验证证据**：串行化前 `✘ Test successfulSyncEndToEnd() ... requestedPaths → ["/api/health", "/api/health", "/api/trending", "/api/trending", ... "/api/media/m1" ...]`（路径成对出现+混入他测试请求）；加 `.serialized` 后 4 项全过（2026-09-22，WhatsNewEngineTests）。
- **易错点**：失败信息落在断言处（如"匹配数不对"），看起来像业务 bug；先怀疑测试基础设施（并行/共享状态）再怀疑业务代码。