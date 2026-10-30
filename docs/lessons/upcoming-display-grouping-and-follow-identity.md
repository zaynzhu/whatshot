# 待播展示归并与平台收藏身份分离

## 结论速览

最终方案：用可重算的作品键合并展示并在分页前分组；收藏、关注时间、变动及已读继续绑定平台 release ID，取消只作用于明确列出的 ID。
适用条件：多个平台排期合成一张作品卡、身份映射可能变化、用户可能只关注部分平台；不能假定一张卡代表所有平台都已关注。

## ✅ 动态归并展示，同时保留独立收藏历史（2026-10-30）

- **环境**：macOS 26.6.2（25G83）、Apple Swift 6.3.3、系统 SQLite3、Swift Testing；数据库使用单连接 actor 串行队列。环境版本在落盘当轮读取，SQLite 具体版本未记录。
- **为何值得记**：跨平台归并影响分页、窗口、收藏、计数、取消和历史，逐处修补会遗漏约束。本次经过方案自审、数据库集成测试及原生应用验收，确认可以不迁移旧收藏记录完成联动。
- **最终方案**：归并输入使用当前启用来源的活跃排期；想看页额外纳入已收藏但已移出片单的最后快照。复用同一身份核验和归并保护，生成键后交给 SQL 做分组、日期过滤及分页。

  收藏写入保留以下实际 SQL 原文，不以重新关注覆盖旧记录：

```sql
INSERT INTO upcoming_wants(release_id,group_id,payload,active,added_at) VALUES(?,?,?,?,?)
ON CONFLICT(release_id) DO NOTHING
```

  完整实现分别见 [UpcomingGrouping.swift](../../macos/Sources/WhatShotCore/Persistence/UpcomingGrouping.swift)、[UpcomingWishlistStore.swift](../../macos/Sources/WhatShotCore/Persistence/UpcomingWishlistStore.swift)。业务边界和完整实施验收以 [作品联动设计](../plans/work-connections.md#想看收藏跟随作品归并2026-10-30) 为权威，经验库不复制流程。

  在项目根可直接复制的本次实际测试命令：

```sh
scripts/test-macos.sh --filter 'UpcomingWantGroupingTests|UpcomingWishlistTests|FollowActivityTests|UpcomingIdentityGroupingTests'
```

- **为什么这样做**：身份映射只是当前证据，可变化、失效或产生冲突；把展示组永久写成收藏身份，会让拆分和取消牵连历史。以 release ID 保留事实，展示键可重算，旧 `group_id` 无需删除或改写。
- **适用条件**：当前项目的有限待播缓存，未加载主片库全量；同大类／地区／发行方式内归并。异名电影需要核实身份，剧集没有季级证据时不跨名称合并；同源多 ID 或冲突整组拆开。具体规则仍以项目设计和代码为准。
- **验证证据**：本会话原始工具输出：

```text
✔ Test run with 20 tests in 4 suites passed after 0.080 seconds.
```

  [UpcomingWantGroupingTests.swift](../../macos/Tests/WhatShotCoreTests/UpcomingWantGroupingTests.swift) 验证分别收藏后归并仍保留 `group_id`、`added_at`、事件 ID 和已读状态，重开持久化、补充关注基线、取消失败事务回滚，以及 65 部作品分为 60+5 的分页和计数。原生验收显示 `1/3 → 3/3 → 2/3`，今日／本周各计一部；来源筛选下只取消优酷，其他两平台保留。提交：`3893af8`（身份归并）、`2d717b5`（想看联动）。
- **交叉验证**：单 agent 自审与自动化／原生验收，无多 agent 交叉审查。书面自审在 [作品联动设计](../plans/work-connections.md)，不标“精粹”。
- **关键步骤**：
  1. 在同一数据库队列操作中读取待播和身份缓存，确定展示分组；完整候选组检查冲突，不能只逐对贪心合并。
  2. 先分组，再决定窗口及分页；列表和总数使用相同查询口径。
  3. 想看卡可以附带未关注平台，但今日／本周只由已关注且活跃的平台排期触发，新增平台必须显式关注。
  4. 补充关注保存本次最新快照与本次关注时间，不回填关注前排期变动，不重置原平台记录。
  5. 取消前显示具体平台，按这批 release ID 在事务内删除；不要按历史组扩张。操作失败连事件和已读清理一起回滚。
- **易错点**：把 `contains(已收藏)` 当“整卡已关注”；未关注平台日期触发今日计数；在 UI 首屏之后去重；通过同名中间条目连接冲突身份；永久迁移收藏组；取消可见平台却删除隐藏平台。弹窗目标的可靠传递见 [SwiftUI item 弹窗经验](swiftui-popover-item-state.md)。
- **证据边界**：异名电影归并已由构造的数据库集成用例验证。核对真实片单时，尚没有足够身份证据的异名组可做实机证明；《坠落2》等不同写法不能据此宣称已经全部去重。真实历史与改档的非空路径由测试库验证，没有向用户库注入假排期。

## ⛔ 按旧 group_id 扩大取消范围（2026-10-30）

- **环境**：同上；旧实现可从 `2d717b5^` 的 `UpcomingWishlistStore.swift` 查看。
- **报错原文**：没有异常；这是静态代码证实的范围错误。旧 SQL 原文：

```sql
DELETE FROM upcoming_wants WHERE group_id=?
```

  旧代码先用当前卡片的 release ID 找组，再删除组内所有记录；当用户筛选某一平台时，该组可能仍含隐藏平台。
- **报错稳定片段**：`DELETE FROM upcoming_wants WHERE group_id=?`；不是异常码。
- **错误原因**：把历史展示分组当作本次用户操作范围，实际删除集合大于当前明确列出的 release ID。
- **为何不可再采用**：存在部分平台筛选、来源关闭或身份重新分组时，旧组不再等于当前可见作品卡。静态审查已确认集合扩张，不宣称曾误删用户真实数据。
- **替代方案**：事务内按明确 release ID 删除；新集成用例 `cancellationOnlyTouchesExplicitIDsEvenForLegacyGroupAndRollsBackFailure` 验证旧组只删一个平台时，其余平台的收藏及已读历史仍保留。
- **判定时效**：2026-10-30，平台级独立收藏及筛选语义下适用；若未来业务明确改为全平台统一取消，需要重新设计范围提示和数据契约。
- **交叉验证**：单 agent 静态审查，修复后的行为经集成测试与实机验证。
