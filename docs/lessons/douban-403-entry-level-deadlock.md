# 豆瓣 403：条目级与 IP 级风控混判 → 补全队列死循环

> 结论速览：
> **最终方案**：批内第 1 次 403 视为条目级——只置 `premiere_fetched_at`（24h 重查退避）继续本批且不产 warning；批内第 2 次 403（另一条目也被拒）才判 IP 风控停批；401 立即停批、429 尊重 Retry-After 均不变。实现见 `macos/Sources/WhatShotCore/Sync/SyncEngine.swift` 的 `backfillPremieres`（`catch ... where status == 403` 分支）+ `VideoRepository.markPremiereBlocked`。
> **适用条件**：任何"单条目级失败 + 一失败就停整批"的补全队列组合（豆瓣 rexxar 这类条目级限制常见的外部源尤其高危）。

## ✅ 403 一律当风控时，单个条目级 403 钉子户把整个补全队列堵成死循环（2026-09-29）

- **为何值得记**：连续 12 轮同步（4 天）状态"部分完成"、首播日补全颗粒无收，根因与"IP 被豆瓣封"表象完全相反；诊断方法论（观测表三步定位 + curl 对照）可直接复用，修复机制零新增存储。
- **最终方案**：`SyncEngine.backfillPremieres` 内 `seenBlocked403` 标记——批内第 1 次 403 走 `markPremiereBlocked`（只 UPDATE `premiere_fetched_at`，不动 `premiere_date`/`premiere_source`）后 `continue`；第 2 次 403 才 `break` 停批。候选出队天然过滤退避中条目（`premiereCandidates` 的 24h 重查 WHERE），无需独立跳过名单表。
- **为什么这样做**：
  - 失败信号必须区分**环境级**（IP 风控、限流：对所有请求生效）与**条目级**（单个资源被源站限制：只对它生效）。"任一失败即停批"的规则只对环境级正确；条目级失败配上"最活跃条目永远排队头"的排序 = 队头死循环。
  - 下一条的正常业务请求就是最便宜的风控探针：它成功 → 条目级实锤；它也 403 → 环境级停批。比独立探针省请求，且停批护栏保留（真风控时只多付 1 条请求）。
  - 退避复用 `premiere_fetched_at` 的 24h 重查机制（与 no_date 同口径）：钉子户每 24h 只消耗 1 条 403 请求、豆瓣解禁后自动恢复补全，无需新表/KV。
- **适用条件**：豆瓣 rexxar `m.douban.com/rexxar/api/v2`（无开放 API 的借用接口，条目级限制实测存在）；项目有 `premiere_fetched_at` 同款"成功后置时戳 + 24h 重查"机制可复用时零成本迁移。
- **验证证据**（全部为当轮生产库与 curl 真实输出）：
  - 诊断链：`sync_runs` 连续 12 轮 error 均为 `豆瓣拒绝访问(HTTP 403)，本批补全中止；已补 0 部` → `douban_requests` 按 run_id 分组：每轮仅 1 条 403 且 douban_id 集中（38232831/37295319），同轮海报批 60 条全 200 → 对照 curl（同 UA/Referer/同 IP，隔 2.5s）：`/rexxar/api/v2/tv/38232831` → `403`，`/tv/38392214` → `200`。
  - 修复后（run 75，2026-09-29 10:07）：第 1 条 38232831 403 → 退避续批 → 第 2-5 条连补 4 部 `got_date` → 第 6 条 37295319 403 → 停批（批内第 2 次，判定正确）；error 文案变为 `已补 4 部`。下一轮起两个钉子户退避中，批恢复 success（预警兑现中，最终以后续 sync_runs 为准）。
  - 测试：121 测试全过，`PremiereTests` 新增 4 个（单 403 续批不产 warning / 双 403 停批后次轮自愈 / 401 立即停批 / 退避不碰已有日期），stub 按 URL path 无状态分发（见 [[swift-testing-parallel-stub-pollution]] 避免静态状态并行污染）。
- **交叉验证**：单 agent 诊断 + 用户拍板方案；根因判定有 curl 对照与生产 run 75 双重证据。定案决策链（与 2026-09-14 红队缓议"探针"方案的区别论证）见 `docs/requirements.md` 定案二修订（commit d9dd4e9）。
- **关键步骤（诊断三步法，遇"每轮部分完成"直接照抄）**：
  1. `sqlite3 ~/Library/"Application Support"/WhatShot/whatshot.sqlite3 "SELECT id, datetime(started_at,'unixepoch','localtime'), status, error FROM sync_runs ORDER BY id DESC LIMIT 12;"` —— 看 warning 文案模式（是否恒为同一步骤、已补数是否恒 0）。
  2. `SELECT douban_id, batch_index, http_status, outcome FROM douban_requests WHERE run_id=<最新轮> ORDER BY id;` —— 403 落点 + 同轮其余请求结果：1 条 403 + 60 条 200 = 条目级；多条 403 无 200 = 环境级。
  3. curl 同头对照（间隔 ≥2s 遵守限频）：钉子户 id vs 同轮 200 的 id，稳定 403 vs 200 即实锤条目级。
- **易错点**：
  - **新逻辑上线后首轮仍可能"部分完成"**——库内有多个钉子户时轮流触发"批内第 2 次 403"停批，各退避一轮后收敛。别误判为修复失败（2026-09-29 用户实际撞上，run 75 即此形态：已补 4 部 + 停批）。
  - **观测表 403 条数 ≠ 风控强度**：1 条 403 + 60 条 200 说明 IP 根本没被封，按 403 计数器思路调限频/熔断是南辕北辙。
  - `setPremiereDate(date: nil)` 会连 `premiere_date`/`premiere_source` 一起置 NULL——退避必须用只置 `premiere_fetched_at` 的 `markPremiereBlocked`，防将来候选口径变化时覆盖豆瓣好值。
  - **残余风险**：海报批 `backfillPostersViaDouban` 未加同款区分。钉子户当前有海报不进海报候选（12 轮海报批零 403），若将来"丢海报 + 被豆瓣 403"组合出现会复现同款死循环，症状是 warning 文案带"豆瓣海报兜底"路径的中止文案。

## ⛔ 旧规则"401/403 立即停批、不重试不绕过"在条目级 403 场景必死循环（2026-09-29 废弃）

- **症状原文**（sync_runs.error 连续 12 轮逐字一致）：
  ```
  豆瓣拒绝访问(HTTP 403)，本批补全中止；已补 0 部，剩余下轮继续
  ```
- **报错稳定片段**：`HTTP 403`、`本批补全中止`、`已补 0 部`（grep 命中即中招；run_id、日期为变量）。
- **错误原因**：规则把 403 一律当 IP 级风控信号（2026-09-14 定案时 403 确实是 IP 级计数器形态：等差 2s 节奏打 195 条后拦在第 9/12/14 条），但 9-24 起豆瓣对该 IP 的 403 已变为条目级（同轮他条 200）；候选按 `seed_updated_at DESC` 排序使活跃连载番钉子户永远占队头 → 每轮第 1 条必 403 → 必停批 → 下轮原样重来。
- **为何不可再采用**：只要存在任一条目级 403 条目且它排在队头，此规则下补全队列永久停滞，且每轮白占 warning 掩盖真实同步质量。
- **替代方案**：见本文件 ✅ 条目（批内首次 403 条目级退避 + 第 2 次停批）。
- **判定时效**：基于 2026-09-29 豆瓣行为。若豆瓣恢复全站 IP 级风控（任意条目都 403），新规则的第 2 次 403 停批护栏仍能兜底，但"每批多付 1 条请求"的代价会随钉子户退避失效而回归——届时回看 `douban_requests` 观测表复测形态再议。
