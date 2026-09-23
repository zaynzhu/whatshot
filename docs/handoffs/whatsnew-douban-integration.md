# WhatsNew 豆瓣数据 × WhatShot 结合：交接（事实清点 + 待拍板事项）

## 立即接手

- 交接类型：发送端，调查结论转执行；下一位角色：WhatShot 执行 agent，但**本文档不含已拍板方案**——三个候选方向全部需要用户先拍板，见「决定、建议与待拍板」表。未获用户确认前不写实现代码。
- 用户目标：了解 WhatsNew（用户自有 NAS 服务）里有哪些豆瓣相关数据、与 WhatShot 结合的价值与边界；在此基础上决定接什么、不接什么。
- 当前状态（2026-09-23 快照）：**只完成核对与实测，豆瓣结合部分零实现**。外部热度主体（定案八）已实现并交付，见 `docs/handoffs/whatsnew-popularity-integration.md` 的执行回执——豆瓣**身份匹配**是其中唯一已上线的豆瓣相关能力。
- 第一步：向用户逐条确认「决定、建议与待拍板」表中 4 个待拍板项；用户选定方向后再做对应实现。
- 完成标准：按用户拍板范围实现、验证并打包；未拍板的方向保持现状，不得顺手实现。

## 定位、状态与必读

快照日期：2026-09-23。下文相对 WhatShot 根目录；`../whatsnew/` 相对同一父目录。

| 仓库 | 当前机器定位 | 分支 / HEAD（写文时） | 说明 |
|---|---|---|---|
| WhatShot | `/Users/zaynzhu/code/claude code/project/whatshot` | `main`，外部热度主体已交付至 `44fa941` | 接手时重新核对 |
| WhatsNew | `/Users/zaynzhu/code/claude code/project/whatsnew` | `codex/whatsnew-mvp` / `57c0035` | **只读，禁改**（WhatShot 规则未撤销） |
| WhatsNew 服务 | `http://192.168.50.233:50016`（用户自有 NAS，用户 2026-09-22 提供） | 部署版本未知 | 全部实测走这里 |

必要阅读顺序：

1. `AGENTS.md`、`CLAUDE.md`：WhatShot 规则（豆瓣口径定案二/五/六、禁改 ../whatsnew）。
2. `docs/requirements.md` 定案二/五/六（豆瓣首播日与海报兜底的既有链路）+ 定案八（外部热度已上线部分）。
3. `docs/handoffs/whatsnew-popularity-integration.md`：外部热度执行回执（API 契约实测、匹配覆盖数据、局限）。
4. `../whatsnew/docs/integration-guide.md` + `../whatsnew/backend/prisma/schema.prisma`：ratings/sourceRefs/poster 的字段定义。
5. `macos/Sources/WhatShotCore/Networking/WhatsNewClient.swift`、`ExternalHeatStore.swift`：现有客户端与快照表（豆瓣结合若落地，复用面在这里）。
6. `macos/Sources/WhatShotCore/Sync/SyncEngine.swift`（backfillPremieres / backfillPostersViaDouban）+ `DoubanClient.swift`：WhatShot 自家豆瓣直连链路（借道方案的对照对象）。

## 已核实的 WhatsNew 豆瓣数据能力（全部实测，非推断）

实测方法：curl 真实服务（2026-09-22）+ 对码 `../whatsnew/backend` 源码。作品样本：「一瓯春」（douban-35644140，与 WhatShot 库内条目 94026 同 ID）、「蜘蛛侠：崭新之日」（库内 93980）。

### 1. 豆瓣作品身份 —— 已在用（定案八匹配通道）

- `GET /api/media/:id` 的 `sourceRefs` 含 `{source: "douban", sourceId: "douban-<subject_id>"}`（源码 `doubanParser.ts` 写死此格式）。
- 实测：`douban-35644140` ↔ WhatShot 库 `videos.douban_id = 35644140` 精确命中（youku_reserve 抽样 2/2 命中）。
- 注意：部分作品**没有** douban ref（iqiyi/tencent/bilibili 抽样 4 部无身份）——豆瓣身份覆盖不是 100%。

### 2. 豆瓣评分 —— 数据在，WhatShot 未接

- 实测「蜘蛛侠：崭新之日」ratings 数组：`douban 7.8/10 votes=365671 capturedAt=…`，同作品还有 imdb 8.1、rotten_tomatoes 90/100 与 98/100（critics/users 分行）、tmdb——**WhatsNew 的 NAS 服务自己抓好的，WhatShot 客户端零豆瓣请求即可获得**。
- ratings 表定义（schema.prisma）：source/audience/value/scale/voteCount/sourceUrl/capturedAt，豆瓣 scale=10。
- **覆盖不是 100%**：实测「一瓯春」（未开播）ratings 为空。评分按 `@@unique([mediaItemId, source, audience])` 存当前值。
- WhatShot 现状：库内 `douban_score` 来自 butai0 转载（字符串，无投票数无采集时间）。

### 3. 豆瓣榜单信号 —— 数据在流转，UI 已被动展示

- WhatsNew 有三个豆瓣来源：`douban_top`（TOP250 口碑）、`douban_upcoming`（即将播出，实测 window="豆瓣剧集即将播出"，rank=2）、`douban_upcoming_hot`（预约热度，实测 scope=series rank=18）。
- 三者都**不参与** WhatsNew 的 heatScore（`popularityMovement.ts` 的 `NON_HEAT_SIGNAL_SOURCES` 明确排除）。
- 2026-09-22 trending 快照：68 条信号中 douban_upcoming 1 条 + douban_upcoming_hot 1 条（覆盖少，非每轮都有）。
- 这类信号**已经在** WhatShot 的外部热度页出现（trending 无筛选全量返回、定案八快照表照存照展示）——无需新开发，但 UI 目前不区分"预约/待播/口碑"与动态热度的语义差异。

### 4. 豆瓣海报（借道代理） —— 可用，WhatShot 未接

- WhatsNew 有自己的海报兜底链路：实测「一瓯春」posterUrl 指向 TMDB w500（它对豆瓣通用占位图按 missing 处理，integration-guide 明确 `/pics/subject/movie*.jpg` 类不算真海报、代理返回 404）。
- 海报代理 `GET /api/media/:id/poster` 实测：HTTP 200、image/webp、68KB、带服务端磁盘缓存与 Cache-Control（86400 + stale-while-revalidate）。
- WhatShot 现状：豆瓣海报由 App **自己直连 doubanio**（`backfillPostersViaDouban`：6.5±1.5s 抖动 + 每轮 ≤30/60 条护栏 + douban_requests 观测表 + doubanio Referer 418 防盗链处理）。

### 5. 首播日 —— 口径未核对，不能直接替换

- WhatsNew `MediaItem.firstReleaseDate` 是单值 String；取值口径（是否"全地区取最早"、是否豆瓣 pubdate 口径）**未核对**，与 WhatShot 定案二"收集 pubdate 数组全部完整日期取最早"不同源。
- WhatShot 库 771 条已全部有 premiere_date（豆瓣直连补全完成 + TMDB 分季补全）。

## WhatShot 既有豆瓣直连链路（借道方案的对照成本）

- **首播日**：App 直连 rexxar；2026-09-21 用户熔断定案「不做熔断仅保留观测」——6 天 558 条实测仅 9-15 当天 2 条 403，9-16 起连续 5 天零 403，6.5±1.5s 抖动已够。首播日补全已基本完成（771/771）。
- **海报兜底**：App 直连 doubanio 抓 pic.large，存量清偿后主要防新增坏图条目。
- **风险现状**：豆瓣风控观测连续为零，自家直连**当前没有在燃烧的火**——借道的收益是"长期撤防"而非"救火"。

## 决定、建议与待拍板

| 事项 | 状态 | 说明 |
|---|---|---|
| 豆瓣身份匹配（定案八通道） | 用户已确认并已上线 | 无待办 |
| 豆瓣榜单信号展示 | 事实上已随定案八上线 | 开放问题：是否在 UI 区分"预约/待播/口碑"语义（WhatsNew 端本就不计入热度分）；未拍板 |
| A. 详情浮层展示 WhatsNew 豆瓣评分（含投票数/采集时间，与 butai0 转载分并列对照，不混算） | **模型建议，待用户拍板** | 改动最小（detail 已在客户端能力内）；覆盖受 WhatsNew 库范围限制 |
| B. 海报借道 WhatsNew 代理（未关联条目已借道展示；库内豆瓣兜底是否改借道） | **模型建议，待用户拍板** | 收益=WhatShot 对豆瓣请求趋零；代价=改动既有 `backfillPostersViaDouban` 链路、 WhatsNew 只覆盖其库内作品（WhatShot 771 条不能全靠它）；自家直连当前零 403，非救火场景 |
| C. 首播日借道 WhatsNew | **模型建议，待用户拍板 + 先核口径** | WhatsNew firstReleaseDate 口径未核对（WhatShot 定案是"全都要取最早"）；库内已 771/771 补全，实际增量可能很小 |
| 追剧反查（WhatsNew 新增按 ID 批量查询端点） | 跨项目待办（前一份交接已记） | 需 WhatsNew 修改授权，与豆瓣专项独立 |
| WhatsNew 服务端豆瓣评分/海报的**实际覆盖率**（它库里多少作品带 douban rating/可用海报） | **未知，未核对** | 上述 B/C 的收益评估依赖此项；拍板前可先只读统计（`/api/media?q=` 逐页抽样或看其库规模） |

**修改边界**：WhatShot 规则禁改 `../whatsnew` 未撤销——方向 B/C 若涉及 WhatsNew 端改动（目前看不需要，现有端点已够），先交回协议需求。豆瓣评分/海报/信号全部只读端点即可获得，无需 WhatsNew 改动。

**红线不变**：不跨源混算排名（ WhatsNew 豆瓣分与 butai0 转载分只可对照展示，不合并写库）； WhatsNew 地址只存本地；WhatsNew 服务仅限可信内网。

## 本轮不做

按用户指示，本文档**不含实现方案**（无表结构变更、无端点选型、无代码计划）——用户拍板 A/B/C（或否决）后，由执行 agent 就选定方向出方案再实施。前一份交接（whatsnew-popularity-integration.md）的"本轮不做"清单继续有效。

## 交回要求与接手约定

1. 先核对两仓库 HEAD、服务可达性与用户当前要求；本文是事实快照，不扩大权限。
2. **四个待拍板项未获用户确认前，不写任何豆瓣结合的实现代码**；用户已确认的方向按 WhatShot 规则原子提交（`type: 中文描述`）。
3. 实现后验证：单测 + `./scripts/test-macos.sh` + `./scripts/build-macos-app.sh` 打包；豆瓣相关口径变更（如评分来源标注）同步 requirements.md 并最小同步 AGENTS/CLAUDE。
4. 真实数据核对照抄前一份交接的隐私口径：只报统计，不逐条公开用户清单； WhatsNew 地址不进 git/日志。
5. 完成后更新本文档为实际状态；仅只读权限时在回复中给回执。建议下一位角色：执行（获拍板后）。