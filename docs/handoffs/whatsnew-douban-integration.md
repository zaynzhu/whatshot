# WhatsNew 豆瓣数据 × WhatShot 结合：执行完成，交回只读审查

## 立即接手

- 交接类型：执行交回；下一位角色：**只读审查**。
- 用户目标：利用用户自有 WhatsNew 的豆瓣数据补充 WhatShot 展示，保持来源与身份边界。
- 用户已确认（2026-09-23，本轮原话）：**“榜单做，A 做，B 先调查，C 暂缓”**。无需重新确认 A 与榜单；B 未获实施授权，C 保持暂缓。
- 当前状态：榜单语义区分与详情豆瓣评分对照已实现，B 只读调查已完成；验证与交付证据见文末执行回执。
- 第一步：核对当前规则、Git 状态与执行回执，审查评分隔离、精确匹配、预算/缓存与榜单语义；不要擅自实施 B/C。
- 完成标准：已确认范围实现、测试、打包；不混算、不覆盖主数据评分、不改变首播日与海报链路。

## 给接手者的完成摘要

用户拍板后，执行者已实际修改代码并完成测试、真实服务联调与本机打包，不是只写了建议。

- **已经做完**：豆瓣榜单区分口碑/待播顺序/预约；本地作品详情增加 WhatsNew 豆瓣评分、评价人数、采集时间，与 butai0 转载分对照。
- **只做调查**：库内海报借道。调查结果与局限见下文，未替换获取方式。
- **完全未实施**：首播日借道（用户暂缓）。
- **使用状态**：只生成 `dist/WhatShot.app`，未安装到 Applications、未重启或替换用户正在运行的应用。正式本地数据库未被联调修改；新包运行后才会按正常启动/同步流程补表和缓存评分。
- **代码基准**：实施提交 `f3d8d6c`（`feat: 展示外部豆瓣评分并区分榜单语义`），其父提交 `cf2ea00`。审查使用 `git diff cf2ea00..f3d8d6c`。本次交回只补充交接说明，不再修改实现。
- **核对状态**：本次更新交接前两仓库工作区均干净；WhatShot 为 `main / f3d8d6c`，WhatsNew 为 `codex/whatsnew-mvp / 49a523f`。下面测试证据来自前一实施轮，适用于 `f3d8d6c`；本次交接没有重跑测试、访问 NAS 或读取正式库。

## 定位、状态与必读

快照日期：2026-09-23。下文相对 WhatShot 根目录；`../whatsnew/` 相对同一父目录。

| 仓库 | 当前机器定位 | 分支 / HEAD（写文时） | 说明 |
|---|---|---|---|
| WhatShot | `/Users/zaynzhu/code/claude code/project/whatshot` | `main`，实施提交 `f3d8d6c`，审查基线 `cf2ea00` | 接手时重新核对 |
| WhatsNew | `/Users/zaynzhu/code/claude code/project/whatsnew` | `codex/whatsnew-mvp` / `49a523f` | **只读，禁改**（WhatShot 规则未撤销） |
| WhatsNew 服务 | 用户已配置的可信内网 NAS（地址仅本地保留） | 部署版本未知 | 全部实测走这里 |

必要阅读顺序：

1. `AGENTS.md`、`CLAUDE.md`：WhatShot 规则（豆瓣口径定案二/五/六、禁改 ../whatsnew）。
2. `docs/requirements.md` 定案二/五/六（豆瓣首播日与海报兜底的既有链路）+ 定案八/九（外部热度与本轮评分/语义范围）。
3. `docs/handoffs/whatsnew-popularity-integration.md`：外部热度执行回执（API 契约实测、匹配覆盖数据、局限）。
4. `../whatsnew/docs/integration-guide.md` + `../whatsnew/backend/prisma/schema.prisma`：ratings/sourceRefs/poster 的字段定义。
5. `macos/Sources/WhatShotCore/Networking/WhatsNewClient.swift`、`macos/Sources/WhatShotCore/Persistence/ExternalHeatStore.swift`：本轮评分解码、身份与评分缓存、查询和事务写入。
6. `macos/Sources/WhatShotCore/Sync/SyncEngine.swift`（backfillPremieres / backfillPostersViaDouban）+ `DoubanClient.swift`：WhatShot 自家豆瓣直连链路（借道方案的对照对象）。

## 前轮调查快照（2026-09-22，当前状态以执行回执为准）

实测方法：curl 真实服务（2026-09-22）+ 对码 `../whatsnew/backend` 源码。作品样本：「一瓯春」（douban-35644140，与 WhatShot 库内条目 94026 同 ID）、「蜘蛛侠：崭新之日」（库内 93980）。

### 1. 豆瓣作品身份 —— 已在用（定案八匹配通道）

- `GET /api/media/:id` 的 `sourceRefs` 含 `{source: "douban", sourceId: "douban-<subject_id>"}`（源码 `doubanParser.ts` 写死此格式）。
- 实测：`douban-35644140` ↔ WhatShot 库 `videos.douban_id = 35644140` 精确命中（youku_reserve 抽样 2/2 命中）。
- 注意：部分作品**没有** douban ref（iqiyi/tencent/bilibili 抽样 4 部无身份）——豆瓣身份覆盖不是 100%。

### 2. 豆瓣评分 —— 当时未接，本轮已接

- 实测「蜘蛛侠：崭新之日」ratings 数组：`douban 7.8/10 votes=365671 capturedAt=…`，同作品还有 imdb 8.1、rotten_tomatoes 90/100 与 98/100（critics/users 分行）、tmdb——**WhatsNew 的 NAS 服务自己抓好的，WhatShot 客户端零豆瓣请求即可获得**。
- ratings 表定义（schema.prisma）：source/audience/value/scale/voteCount/sourceUrl/capturedAt，豆瓣 scale=10。
- **覆盖不是 100%**：实测「一瓯春」（未开播）ratings 为空。评分按 `@@unique([mediaItemId, source, audience])` 存当前值。
- WhatShot 现状：库内 `douban_score` 来自 butai0 转载（字符串，无投票数无采集时间）。

### 3. 豆瓣榜单信号 —— 当时被动展示，本轮已区分语义

- WhatsNew 有三个豆瓣来源：`douban_top`（TOP250 口碑）、`douban_upcoming`（即将播出，实测 window="豆瓣剧集即将播出"，rank=2）、`douban_upcoming_hot`（预约热度，实测 scope=series rank=18）。
- 三者都**不参与** WhatsNew 的 heatScore（`popularityMovement.ts` 的 `NON_HEAT_SIGNAL_SOURCES` 明确排除）。
- 2026-09-22 trending 快照：68 条信号中 douban_upcoming 1 条 + douban_upcoming_hot 1 条（覆盖少，非每轮都有）。
- 这类信号**已经在** WhatShot 的外部热度页出现（trending 无筛选全量返回、定案八快照表照存照展示）——前轮 UI 尚未区分"预约/待播/口碑"与动态热度，本轮已补齐区分。

### 4. 豆瓣海报（借道代理） —— 可用，WhatShot 未接

- WhatsNew 有自己的海报兜底链路：实测「一瓯春」posterUrl 指向 TMDB w500（它对豆瓣通用占位图按 missing 处理，integration-guide 明确 `/pics/subject/movie*.jpg` 类不算真海报、代理返回 404）。
- 海报代理 `GET /api/media/:id/poster` 实测：HTTP 200、image/webp、68KB、带服务端磁盘缓存与 Cache-Control（86400 + stale-while-revalidate）。
- WhatShot 现状：豆瓣海报由 App **自己直连 doubanio**（`backfillPostersViaDouban`：6.5±1.5s 抖动 + 每轮 ≤30/60 条护栏 + douban_requests 观测表 + doubanio Referer 418 防盗链处理）。

### 5. 首播日 —— 口径未核对，不能直接替换

- WhatsNew `MediaItem.firstReleaseDate` 是单值 String；取值口径（是否"全地区取最早"、是否豆瓣 pubdate 口径）**未核对**，与 WhatShot 定案二"收集 pubdate 数组全部完整日期取最早"不同源。
- 前轮记载“771/771 已有 premiere_date”，本轮未复现该口径，不再用于判断当前库；当前按电影/剧集分开统计见执行回执。

## WhatShot 既有豆瓣直连链路（借道方案的对照成本）

- **首播日**：App 直连 rexxar；2026-09-21 用户熔断定案「不做熔断仅保留观测」——6 天 558 条实测仅 9-15 当天 2 条 403，9-16 起连续 5 天零 403，6.5±1.5s 抖动已够。前轮首播日数量结论已被当前分类型统计替代（见执行回执）。
- **海报兜底**：App 直连 doubanio 抓 pic.large，存量清偿后主要防新增坏图条目。
- **风险现状**：豆瓣风控观测连续为零，自家直连**当前没有在燃烧的火**——借道的收益是"长期撤防"而非"救火"。

## 决定与边界

| 事项 | 状态 | 说明 |
|---|---|---|
| 豆瓣身份匹配 | 既有能力，保留 | 稳定 ID 精确匹配，类型隔离与冲突保护 |
| 榜单语义 | 用户确认，已实现 | 口碑、待播日期分组顺序、预约分别标明；这三类不显示热度涨跌/NEW |
| A. 详情豆瓣评分对照 | 用户确认，已实现 | 来源、10 分制、投票数、采集时间与本地检查时间独立展示，不覆盖 butai0 转载分 |
| B. 库内海报借道 | 用户仅授权调查，调查已完成 | 建议暂保留现有链路；不是用户否决接入，进一步实施仍需拍板 |
| C. 首播日借道 | 用户确认暂缓 | 未核口径，不实施 |
| 追剧反查批量 ID 端点 | 跨项目待办 | 本轮不修改 WhatsNew |
| 覆盖率 | 海报全库聚合与评分小样本已核对 | 不把样本比例当全库豆瓣评分或本地坏图覆盖率 |

**修改边界**：WhatShot 规则禁改 `../whatsnew` 未撤销——方向 B/C 若涉及 WhatsNew 端改动（目前看不需要，现有端点已够），先交回协议需求。豆瓣评分/海报/信号全部只读端点即可获得，无需 WhatsNew 改动。

**红线不变**：不跨源混算排名（ WhatsNew 豆瓣分与 butai0 转载分只可对照展示，不合并写库）； WhatsNew 地址只存本地；WhatsNew 服务仅限可信内网。

## 本轮不做

- 不改 `../whatsnew`，不引入服务端接口，不做标题搜索。
- 不实施库内海报借道，不修改 S3、豆瓣/TMDB 兜底和首播日期链路。
- 不改变 butai0 排名、评分与更新集数，不把豆瓣口碑/待播/预约混入动态热度。
- 不推送、不上传产物、不创建 Release。

## 执行回执（2026-09-23）

### 实际实现

- `WhatsNewClient` 解码豆瓣 users 评分（scale=10、值在 0…10），保留投票数与原始采集时间；不接受返回 ID 与请求 ID 不一致的详情。
- 新增 `external_media_details` 本地缓存，身份与评分同存但与主数据评分隔离；和当轮信号放在同一事务提交。旧库启动通过 `CREATE TABLE IF NOT EXISTS` 补表。
- 详情补查覆盖当前 trending 的有限作品集合，去重后每轮最多 10 部，保持 ≥2 秒限频。按未成功取得/最久未成功取得详情轮换，IMDb 已匹配条目也参与；旧缓存身份可供未轮到条目匹配。
- 成功空评分清除旧评分，单条失败保留旧缓存并报告 warning；站方采集时间与本地检查时间分开展示。由于按成功时间排序，持续失败条目仍会占用下一轮预算，可能延迟其余条目覆盖。
- IMDb 与豆瓣冲突不关联；更新某作品身份时同步更新它保留的旧榜单席位，避免截断保缓存导致旧席位错贴新评分。详情评分按 media ID 去重，仅读本地缓存。
- 外部热度来源按钮、详情信号行改为可解释语义；豆瓣榜单增加说明，隐藏其涨跌与 NEW 提示。来源按钮与网格共享选中来源计算，避免说明与实际榜单不一致。
- `docs/requirements.md` 新增定案九，`AGENTS.md`/`CLAUDE.md` 最小同步。

### B 海报只读调查

方法：读 WhatsNew 源码与私有 API；所有网络请求共享 ≥2 秒间隔，仅 health/trending/media detail/poster-health。无服务端同步、写入或海报下载；本地库只读。仅记录聚合统计，不记录作品清单与服务地址。

- `/api/poster-health` 当前活跃作品 **4,456** 部；有海报 URL **4,311（96.7%）**，缺海报 **145**。服务端状态：healthy **4,300**、degraded **5**、broken **6**、unverified **0**；质量 adequate **4,292**、undersized **13**、unknown **6**。这是服务端已有检查状态，不是本轮逐图实测。
- 当前 trending **68 条信号 / 50 部作品**。按内部 ID 排序取前 **20** 部作便利样本：**20** 部有 posterUrl、**2** 部有豆瓣身份、**2** 部有豆瓣评分；按类型隔离与稳定 ID 检查，**3** 部能与本地关联，三者均有 posterUrl。样本非随机，不能外推全库或本地缺图覆盖率。
- 当前本地库 **813** 部：电影 **460**（缺日期 **459**），剧集 **353**（缺日期 **2**）。前轮“771/771 全补齐”不能作为当前事实；电影日期缺失不能等同于剧集补全失败。
- 海报 URL 分布：localhost **5**、公网 HTTP **217**、内网 HTTP **420**、HTTPS **169**、其他格式 **2**。420 个内网 HTTP 可能属于自有 S3，不能一概算坏图；未下载验证其可用性。
- `/api/media` 当前最多返回 100，`nextCursor: null`，没有分页参数；前轮“逐页统计”建议不适用。不能据此声称已取得全库豆瓣评分覆盖率。
- **模型建议**：暂保留原链路。WhatsNew 海报覆盖好，但双方身份交集仍是瓶颈，20 部样本不足以证明能覆盖本地坏图。若未来实施，先取得稳定 ID 查询能力或可控覆盖证据，再由用户决定；不以标题搜索扩覆盖。

### 验证与交付

- `./scripts/test-macos.sh --filter WhatsNew`：25 项通过；随后补充事务回滚用例。
- `./scripts/test-macos.sh`：**107 项 / 10 套全部通过**。涵盖评分字段校验、空评分清除、失败保缓存、IMDb 路径评分、预算轮换、缓存豆瓣身份、多席位去重、冲突不展示与评分失败整批回滚。
- 真实客户端/同步引擎 × 用户 NAS × 本地库临时副本：**23.177 秒通过**，本轮信号 **68**、缓存详情 **10**、含豆瓣评分 **2**、本地可展示评分 **2**。使用真实 ≥2 秒限频，正式数据库未修改。临时测试文件已删除，不留依赖 NAS 的常规测试。
- `./scripts/build-macos-app.sh`：成功，生成 `dist/WhatShot.app`，ad-hoc 签名与严格签名校验通过；未上传、未创建 Release。
- Git：实现与首次回执在 `f3d8d6c` 原子提交中，提交消息 `feat: 展示外部豆瓣评分并区分榜单语义`；WhatShot main，无推送；WhatsNew 仍干净。
- 尚未人工走查打包 App 的配置→同步→详情交互；全量豆瓣评分覆盖、全部本地坏图的 WhatsNew 匹配率、逐图字节可用性未验证。NAS 实际部署 commit 未知。
- 编译仍有既有 warning（AppModel 冗余 await、可选 window 插值、旧测试 Sendable/未使用变量），未扩展清理范围。

## 建议审查顺序与剩余事项

1. 对照定案九与 `cf2ea00..f3d8d6c`，确认只实施 A 与榜单语义，海报/首播日/WhatsNew 服务端没有变更。
2. 看 `WhatsNewClient.swift`、`SyncEngine.swift`、`ExternalHeatStore.swift` 和相关测试，重点检查身份冲突、旧榜席位关联、成功空评分与失败保缓存、每轮预算；持续失败条目占预算是已知限制，不得把“轮换”理解成必定五轮覆盖全部 50 部。
3. 看 `Models/ExternalSignalMeaning.swift`、`App/ExternalHeatTabView.swift`、`App/DetailSheet.swift`，确认来源标签、非热度提示和评分时间文案。前两类路径分别位于 `macos/Sources/WhatShotCore/` 与 `macos/Sources/WhatShotApp/`。
4. **仍未验证**：新包实际窗口里的排版、配置→同步→详情交互。只读审查可给出检查建议；本交接不自动授权安装、重启应用或触发正式库同步。
5. 输出问题、证据和严重程度；没有问题也应列清尚未验证项。用户未新增授权前，不修代码、不实施 B/C。

## 接手约定与交回要求

1. 核对当前用户要求、两仓库 HEAD/工作区及适用 `AGENTS.md`/`CLAUDE.md`；本文为事实快照，不扩大权限。
2. 已确认 A 与榜单不得再当成待拍板；B 仅调查、C 暂缓。方案变更需要用户明确确认，不自行跨仓库修改。
3. 当前下一位角色为只读审查；发现问题给出证据，不顺手修复。用户明确授权修复后再实施。
4. 保留隐私边界：真实服务地址只在本地设置，不进新增日志/文档；调查只报聚合数据。
5. 完成或需要交回时，更新本文件的改动、验证、偏离、剩余问题与下一步；写前重读避免覆盖后来变化。只有只读权限时在回复给出回执。已授权独立变更验证后按项目规则原子提交。
