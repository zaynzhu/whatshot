# WhatsNew 接口需求交接：批量身份查询端点（WhatShot 消费方提出）

> **状态（2026-09-24）**：本文档为需求建议稿，已实施完成——WhatsNew 端交付 `POST /api/media/lookup`（契约 v1）并对生产 NAS 部署验收通过。**最终契约与对接事实以 `whatsnew-batch-lookup-connect-handoff.md`（含交回摘要与修订）为准**，本文的契约建议不再作为对接依据，仅存背景。

## 立即接手

- 交接类型：发送端，需求转执行；下一位角色：**WhatsNew 项目的执行 agent**（本文档放在 WhatShot 仓库是因为需求方不能改 `../whatsnew`，路径由用户转达）。
- 用户授权（2026-09-23 原话）："你需要的接口你先给我一份交接，然后我让那个项目的去提供，后续什么时候他更新咱们再说这个事"——** WhatsNew 端实现接口已获用户批准**；WhatsNew 端实现完成后的 WhatShot 对接是**另一个任务**，不在本文档。
- 任务：在 WhatsNew 后端新增一个**只读**的批量媒体身份查询端点，让消费方（WhatShot）能拿"本地身份清单"换"匹配结果 + 当前热度信号 + 豆瓣评分"。
- 第一步：核对本文「契约建议」与 WhatsNew 现有规范（AGENTS.md、docs/architecture.md 路由风格、integration-guide 错误语义）的差异，按 WhatsNew 习惯调整契约——**调整后必须把最终契约回传给用户**（WhatShot 端对接依赖它）。
- 完成标准：端点实现 + `npm run typecheck` / `npm test` 通过 + integration-guide 补文档；真实数据抽查（用文末两个公开测试身份）结果符合「返回语义」；**只读红线全守住**。

## 背景：消费方是谁、卡在哪

消费方是 WhatShot（`/Users/zaynzhu/code/claude code/project/whatshot`，用户另一台会话在维护）：本地 SQLite + butai0 单源热度的 macOS 应用，2026-09-22 已接入 WhatsNew 的**现有只读端点**（health / trending / media detail / poster，见其 `docs/handoffs/whatsnew-popularity-integration.md` 执行回执）。当前匹配瓶颈（实测 2026-09-22）：

1. `GET /api/trending` 无筛选只有 heatScore 前 50 部作品——**消费方追剧清单不在 50 部内就完全查不到**（ WhatsNew 无按 ID 查询端点，`/api/media` 是文字搜索且不可翻页，不能用于身份对齐）
2. WhatShot 库内剧集条目的 `imdb_number` 多为"该季第 1 集"的**单集 tt 号**（实测：tt3658012=权游 S5E1），WhatsNew 的 `MediaItem.imdbId` 是作品级——精确相等匹配大量漏配，需要 WhatsNew 端用它的 TMDb/TVDb/Trakt 交叉身份判断能否桥接（能则标明桥接依据，不能则如实 unmatched/ambiguous，**不得用标题相似度补**—— WhatsNew 豆瓣红线"不得标题搜索"同样适用于此）
3. 详情逐条补查受限： WhatsNew 端每作品一次 `/api/media/:id`，消费方每轮预算 ≤10 条、2s 限频——批量接口一次解决

## 消费方的身份特征（查询输入，WhatsNew 端按此理解）

| WhatShot 字段 | 形态 | 与 WhatsNew 的对应 |
|---|---|---|
| `douban_id` | INTEGER（豆瓣 subject 数字，如 35644140） | `MediaSourceRef { source: "douban", sourceId: "douban-<数字>" }`，实测精确对应（"一瓯春" 35644140 ✓） |
| `imdb_number` | TEXT "tt…"；**剧集条目多为该季第 1 集的单集号** | `MediaItem.imdbId`（作品级，有索引）；MediaSourceRef 也有 `imdb:tt…` 形式。**桥接需求**：单集 tt → 作品（WhatsNew 有 TMDb/TVDb/Trakt 交叉身份可用；无法桥接就如实报 unmatched/ambiguous，不做标题猜测） |
| `kind` | 1=电影 2=剧集 | `mediaType` movie/series——**大类绝不互配**（ WhatsNew 规则原文），查询必须带大类约束 |

## 契约建议（**建议而非定案**，WhatsNew 端可按自身规范调整，调整后回传）

### 请求

`POST /api/media/lookup`（批量 ID 用 body，避免 GET URL 长度限制）

```json
{
  "contractVersion": 1,
  "mediaType": "series",
  "doubanIds": [35644140, 36685660],
  "imdbIds": ["tt3658012"],
  "limit": 50
}
```

- 每请求总数上限建议 50（ WhatsNew 端可按数据库查询成本调整，超限返回明确错误而非静默截断）
- `mediaType` 必填（消费方会分电影/剧集两次调用）——大类隔离在服务端强制

### 返回

```json
{
  "contractVersion": 1,
  "counts": { "matched": 2, "unmatched": 1, "ambiguous": 0 },
  "items": [
    {
      "query": { "kind": "douban", "id": 35644140 },
      "status": "matched",
      "mediaId": "cmrij93m9011o14flt2r8i2y1",
      "matchBasis": "douban",
      "matchLevel": "work",
      "titleDisplay": "一瓯春",
      "mediaType": "series",
      "signals": [ /* 与 trending 相同行结构：source/rank/rankingScope/window/rankingEntryKey/capturedAt/isCurrent */ ],
      "doubanRating": { "value": 7.8, "voteCount": 365671, "capturedAt": "…" },
      "imdbId": "…", "tmdbId": 0
    },
    { "query": { "kind": "imdb", "id": "tt3658012" }, "status": "unmatched", "reason": "no_work_level_identity" },
    { "query": { "kind": "imdb", "id": "ttXXXX" }, "status": "ambiguous", "reason": "multiple_candidates" }
  ]
}
```

### 必须守住的三条语义

1. **三种"没有"分开**：库内无此 ID（unmatched，reason 说明）、有作品但无当前信号（matched 但 signals 空数组 + 最近采集时间）、请求级错误（HTTP 错误码）——消费方靠这个区分"没收录/下榜了/查询坏了"，不得混成一个空结果
2. **只读**：不触发来源同步、不写库、不修改设置；复用现有 `GET /api/media/:id` 的数据快照语义
3. **匹配依据可解释**：matchBasis/matchLevel 让消费方能展示"按什么对上的"；桥接（如单集 tt → show）必须标注，消费方不把桥接命中冒充直接命中

### WhatsNew 端红线（其 AGENTS.md 既有约束，本文重申）

- 电影/剧集大类绝不互并；豆瓣不得标题搜索或绕过访问限制
- 评分独立于热度信号（返回结构里分开放，不混算）
- 服务仅限可信内网，本端点不得为此新增公网暴露
- 现有端点契约不得变更（新增路由，不动 trending/media 语义）

### 实现可行性参考（WhatsNew 端核对）

- `MediaItem.imdbId` 有 `@@index`；douban 走 `MediaSourceRef`（`@@unique([source, sourceId])`，`sourceId = 'douban-<数字>'` 精确查）；单集 tt 桥接可查 TMDb `/find` 缓存或 tvdb/trakt 交叉引用—— WhatsNew 端自行评估成本，做不到桥接就只返回直接命中
- 空评分（未开播作品）如实返回 `doubanRating: null`，与"无此作品"区分

## 测试身份（公开样本，非用户私人清单）

- `douban 35644140` → 应匹配"一瓯春"（series，含 douban_upcoming 信号）
- `douban 36685660` → 应匹配"蜘蛛侠：崭新之日"（含 douban rating 7.8/365671 实测值，2026-09-22）
- `imdb tt11280740`（Severance）→ 验证作品级 IMDb 直查

## WhatShot 端对接准备（上下文，非本任务）

WhatShot 端客户端（`WhatsNewClient`）、匹配器（`ExternalHeatMatcher`：IMDb/豆瓣精确相等、电影剧集隔离、双 ID 冲突保护）、缓存表（`external_media_details`）均已就位；接口契约确定后，由用户在 WhatShot 侧发起对接任务（新增 client 方法、追剧反查步骤、评分对照扩展）。

## 交回要求

1. WhatsNew 端按其规则原子提交（`type: 中文描述`），测试与 typecheck 通过后更新 `docs/integration-guide.md` 与 `docs/handoff.md`。
2. **最终契约（端点名、请求/响应结构、批量上限、错误语义、contractVersion）回传给用户**——消费方按最终契约对接，不以本文建议为准。
3. 不部署、不推送、不创建 Release——部署由用户决定（用户当前 NAS 部署版本与仓库 HEAD 的对应关系未知，实现完成后提示用户部署新版本才能被消费方使用）。
4. 本文档为需求快照： WhatsNew 端实施中发现的约束冲突（如索引成本、限频策略）如实记录并在回传契约时说明，不静默偏离。