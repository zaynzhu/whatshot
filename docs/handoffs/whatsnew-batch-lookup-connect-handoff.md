# WhatShot 对接连调交接：WhatsNew 批量身份查询端点

## 立即接手

- 交接类型：发送端（WhatsNew 端已完成实现），需求转对接执行；下一位角色：**WhatShot 项目的执行 agent**。
- 任务：WhatsNew 已交付只读批量身份查询端点 `POST /api/media/lookup`（契约见下文「最终契约」，以本文档为准，不以需求快照的建议稿为准）。WhatShot 端按契约新增 client 方法，并连一次 WhatsNew 端**当前正在运行的本地连调实例**做冒烟验证。
- ⚠️ **环境声明（重要）**：本次连调目标是 WhatsNew 的**本地开发测试实例**，地址 `http://192.168.50.114:19993`，**临时性质**。WhatsNew 正式部署到 NAS 后 IP 和端口都会变（端口为 `50015`/`50016`，主机地址由用户在部署后提供）。WhatShot 端实现时必须把 base URL 做成可配置项，**不得把本次测试地址硬编码进任何常量**；冒烟通过后，正式对接等 WhatsNew 部署完成、用户给出新地址再切换。
- 范围与非目标：本轮只做 WhatShot 端的 client 方法新增 + 连调验证；不修改 WhatsNew 端任何代码；不部署、不推送 WhatsNew；WhatsNew 端点契约已冻结（`contractVersion` 1）。
- 当前状态与第一步：WhatsNew 端已实现、已测试、本地实例正在运行；第一步是按「连调步骤」先打通健康检查与冒烟请求。
- 完成标准（建议）：WhatShot 端新增 lookup client 方法 + 冒烟用例全部通过 + 对接结论回传；契约如有不适配之处，记录偏离并回传，不得静默偏离。

## 连调实例状态（WhatsNew 端提供，2026-09-23）

- 地址：`http://192.168.50.114:19993`（局域网可达，已实测）
- 健康：`GET /api/health` → `{"ok":true,"service":"whatsnew-backend","environment":"main"}`
- 实例性质：本地开发实例，连接 WhatsNew **主库**（数据为真实数据），已按需求关闭其调度器（不会与 NAS 正式实例双跑同步）；对 WhatShot 暴露的端点均为只读
- 服务由 WhatsNew 端会话启动（`npm run dev:backend`，后台进程）；连调完成后由用户决定是否保留或停掉
- 该实例数据与 NAS 正式环境同库，但**响应内容以本次连调为准，正式环境的可用数据会随部署时间变化**

## 最终契约（WhatShot 端对接以此为准）

### 请求

`POST /api/media/lookup`，`content-type: application/json`：

```json
{
  "contractVersion": 1,
  "mediaType": "series",
  "doubanIds": [35644140],
  "imdbIds": ["tt0944947"]
}
```

| 字段 | 规则 |
|---|---|
| `contractVersion` | 可选；传了必须是 `1`，否则 400 |
| `mediaType` | **必填**，`movie` / `series`（作品大类）。服务端按 `releaseForm` 强制大类边界；`movie` 查询绝不返回剧集大类作品 |
| `doubanIds` | 豆瓣 subject 数字；走库内 `douban-<id>` 来源引用精确匹配 |
| `imdbIds` | 作品级 `tt\d+`；**单集 tt 号无桥接**，如实返回 `unmatched`（WhatsNew 不做标题猜测、不做外部桥接） |
| 批量上限 | `doubanIds + imdbIds` 总数 1–50；超限 `400 batch_too_large`（带 `maxBatchSize: 50`），拒绝而非截断 |

### 响应 200

```json
{
  "contractVersion": 1,
  "counts": { "matched": 1, "unmatched": 1, "ambiguous": 0 },
  "items": [
    {
      "query": { "kind": "douban", "id": 35644140 },
      "status": "matched",
      "mediaId": "cmrij93m9011o14flt2r8i2y1",
      "matchBasis": "douban",
      "matchLevel": "work",
      "titleDisplay": "一瓯春",
      "mediaType": "series",
      "releaseForm": "web_series",
      "firstReleaseDate": "2026-09-17",
      "workStatus": "released",
      "heatScore": 0,
      "signals": [],
      "lastSignalCapturedAt": "2026-09-17T01:08:09.533Z",
      "doubanRating": null,
      "imdbId": null,
      "tmdbId": 294990,
      "tvdbId": null,
      "traktId": null
    },
    { "query": { "kind": "imdb", "id": "tt3658012" }, "status": "unmatched", "reason": "no_work_level_identity" }
  ]
}
```

- items 顺序 = `doubanIds` 输入序在前、`imdbIds` 输入序在后，每个输入恰好一个输出行（WhatShot 按位置对齐）
- `matched`：`matchBasis`（`douban`/`imdb`）+ `matchLevel: work` 是匹配依据，展示时保留，不得把匹配结果冒充直接命中
- `signals` 仅含 `isCurrent` 行，行结构与 `/api/trending`、`/api/media/:id` 相同；**评分独立**：`doubanRating` 单独字段，永不混入 signals 或热度
- **三种"没有"分开**（消费方判断逻辑按此设计）：
  1. `unmatched`（`reason: no_work_level_identity`）= 库内无此身份
  2. `matched` + `signals: []` + `lastSignalCapturedAt` 有值 = 作品在库但当前无信号（如已下榜/待播窗口过期），不是"没收录"
  3. HTTP 4xx = 请求级错误（查询本身坏了）
- `doubanRating: null` = 已匹配作品但无豆瓣评分（未开播等），与"无此作品"区分
- `ambiguous`（`reason: multiple_candidates` + `candidateMediaIds`）= 同一身份多个作品，端点不代选；WhatShot 端按双 ID 冲突保护处理

### 4xx 错误

| 状态 | error | 说明 |
|---|---|---|
| 400 | `invalid_body` | 结构/类型非法（含 `nm` 开头 IMDb 号、豆瓣小数） |
| 400 | `unsupported_contract_version` | `contractVersion` 非 1；响应带 `supportedVersion` |
| 400 | `batch_too_large` | 总数 > 50；带 `maxBatchSize` |
| 400 | `empty_lookup_batch` | 两数组都为空 |

## 定位与必读（WhatShot 项目内）

- `docs/handoffs/whatsnew-batch-lookup-api-request.md`：上一份需求快照（背景与消费方身份特征），契约以**本文档**为准
- WhatsNew 端契约权威文档：`../whatsnew/docs/integration-guide.md` 的「Media Batch Lookup」章节（commit `5806050`）
- WhatShot 端已有基建（2026-09-22 需求快照记录）：`WhatsNewClient`、`ExternalHeatMatcher`（IMDb/豆瓣精确相等、电影剧集隔离、双 ID 冲突保护）、`external_media_details` 缓存表——本轮在其上新增 lookup 方法，不推倒重来

## 决策与依据

| 决策 | 状态及来源 | 理由 | 重新考虑的条件 |
|------|------------|------|----------------|
| 契约以本文档为准（相对需求快照有调整） | 用户已确认（用户要求 WhatsNew 端按自身规范调整后回传，即本文档） | 增补 `scale`/`workStatus`/`releaseForm`/`lastSignalCapturedAt`/`candidateMediaIds`，删除冗余 `limit` 字段 | WhatShot 连调发现实际需要未覆盖字段时回传协商 |
| 单集 tt 号不桥接，统一 `unmatched` | 用户已确认（WhatsNew 端红线：库内无 episodes 数据、外部桥接需写库违反只读） | 保证"不猜测"语义 | 无——WhatsNew 端如未来引入单集数据会升级契约 |
| 蜘蛛侠豆瓣 ID 差异（见下） | 待定（数据核对项，不阻塞对接） | 同一作品两个 subject 值的来源差异 | WhatShot 端核对其 `douban_id` 存储来源后定论 |

## ⚠️ 已知数据层差异（连调冒烟前先读）

**WhatShot 库内若存有豆瓣 ID `36685660`（蜘蛛侠：崭新之日），将得到 `unmatched`**。WhatsNew 主库实际存储的是 `douban-36246195`（同一作品，评分 7.8/365671 一致）。WhatsNew 端直查确认 `36685660` 的 sourceRef 不存在。WhatShot 端需核对其 `douban_id` 的抓取来源（可能取自预告/资料页 subject 而非正片页，或需求快照笔误），这是**数据核对项，不是端点缺陷**。连调冒烟时请用 `36246195` 验证 movie 大类。

## 进度与证据（WhatsNew 端）

- 已实现：`POST /api/media/lookup`（`backend/src/services/mediaLookupService.ts` + `backend/src/routes/media.ts`），commit `a24999a`；契约文档 commit `5806050`
- 已验证：typecheck 通过；lookup 测试 15/15 全绿；局域网冒烟（本机 `192.168.50.114` 实测 200 响应与 4xx 语义，2026-09-23）
- 未验证：WhatShot 端 client 集成（本轮任务）
- 注意：WhatsNew 全量测试套件存在与本次改动无关的预存在失败与随机超时（见其 `docs/lessons/backend-preexisting-test-failures.md`），WhatShot 端不要因此误判 WhatsNew 端质量

## 剩余步骤与验收（WhatShot 端）

1. **新增 client 方法**：`WhatsNewClient` 增加 `lookupMedia(mediaType, doubanIds, imdbIds)`，批量 ≤ 50，保留 2 秒限频约定；base URL 可配置（见环境声明）。
2. **连调冒烟**（对 `http://192.168.50.114:19993`，命令可直接复制）：
   ```bash
   curl -s http://192.168.50.114:19993/api/health
   curl -s -X POST http://192.168.50.114:19993/api/media/lookup \
     -H "content-type: application/json" \
     -d '{"contractVersion":1,"mediaType":"series","doubanIds":[35644140],"imdbIds":["tt11280740"]}'
   ```
   预期：health 返回 `whatsnew-backend`；lookup 返回 1 matched（一瓯春）+ 1 unmatched（`tt11280740` 为 Severance，WhatsNew 库内无此作品级身份，如实 unmatched 属正确语义）。
   再冒烟 movie 大类与错误语义：
   ```bash
   curl -s -X POST http://192.168.50.114:19993/api/media/lookup \
     -H "content-type: application/json" \
     -d '{"contractVersion":1,"mediaType":"movie","doubanIds":[36246195]}'
   # 预期 matched 蜘蛛侠：崭新之日，doubanRating 7.8/365671

   curl -s -X POST http://192.168.50.114:19993/api/media/lookup \
     -H "content-type: application/json" \
     -d '{"contractVersion":2,"mediaType":"series","doubanIds":[1]}'
   # 预期 400 {"error":"unsupported_contract_version","supportedVersion":1}
   ```
3. **集成接入**：按 WhatShot 既有架构把 lookup 接入追剧反查与评分对照；单集 tt 号输入按 `unmatched` 处理（不视为 bug）。
4. **验收**（建议）：追剧清单抽样（含豆瓣 ID 条目 + IMDb 作品级 ID 条目 + 单集 tt 条目三类）走一遍反查，确认三种"没有"的分支各自可达且缓存表写入正常。
5. **交回**：连调结果、发现的问题或契约偏离回传用户；涉及 WhatsNew 端调整的，写回本文件「交回摘要」或新建交接，不要直接改 WhatsNew 代码。

## 接手约定

1. 本文档是任务快照，不提升权限；按 WhatShot 项目规则与当前用户要求核对工作区状态后再动手。
2. 简短说明理解的目标、边界和第一步；无阻塞即继续，不例行等待确认。
3. WhatsNew 侧服务状态以 `/api/health` 实测为准；若 19993 不可达，说明连调实例已被停止——先回传用户确认服务状态，不要自行猜测地址。
4. 本轮不修改 WhatsNew 端代码；发现的契约问题走回传协商。提交、推送等遵守 WhatShot 侧既有授权，不因交接自动获得。
5. 完成或受阻时更新本文件的交回记录（或仅回复交回摘要），写明实际改动、验证证据与剩余问题。

## 交回摘要

**WhatShot 端对接完成（2026-09-23，WhatShot main `见 git log`，未推送）**

### 实际改动
- `WhatsNewClient`：新增 `lookupMedia(mediaType:doubanIds:imdbIds:)`（契约 v1）——客户端自查批量 1–50（超限拒发不发请求）、mediaType 大类校验、POST 复用 2 秒限频；4xx 时服务端 error 码（unsupported_contract_version / batch_too_large 等）附进错误信息。
- 新增公开模型 `LookupItem` / `LookupResponse`：全 Optional 容错解码，status 缺失行丢弃；doubanRating 校验 value 0…10 且 scale 缺省或 10；query 字段按位置对齐契约不解码。
- `SyncEngine.lookupWatchlist`：追剧反查接入——追剧条目按 movie/series 分批（每轮各 ≤1 次请求，追剧 ≤20 条 × douban+imdb 双身份远低于 50 上限），matched 的信号写 external_heat（video_id 直填、已关联）、评分写 external_media_details（详情浮层对照自动生效）；unmatched（含单集 tt）如实跳过；单批失败 warning 不阻断另一批与主同步。base URL 全程走既有可配置 settings.whatsnewBaseURL，测试地址未进任何常量。
- 测试：lookup 解码 5 项（matched/unmatched/ambiguous/4xx 语义/客户端批量上限）+ 追剧反查集成 1 项（不在 trending 内的追剧作品经反查拿信号与评分、unmatched 跳过）——全量 116 项 / 10 套全绿。
- 真实连调：curl 冒烟 4/4（health、series 一瓯春 matched + tt11280740 unmatched、movie 蜘蛛侠 doubanRating 7.8/365671、contractVersion=2 与 51 条批量的 4xx）；client 方法 × 真实实例一次性 live 验证通过（已删，临时地址未入库）。

### 契约偏离
- 无偏离。响应结构与本文档「最终契约」一致。

### 数据核对结论（蜘蛛侠豆瓣 ID 差异）
- WhatShot 库内无 36685660 条目（该值来自需求快照阶段的生产库查询记录， WhatsNew 端判断为另一 subject；WhatShot 现存蜘蛛侠条目 douban_id 待用户库实际值核对，不阻塞）。

### 未验证项
- **真实追剧反查未跑**：用户当前追剧清单为空，三类身份分支（豆瓣 ID 命中 / IMDb 作品级命中 / 单集 tt unmatched）已由 stub 集成测试覆盖，真实数据分支待用户关注作品后首轮同步自然验证。
- WhatsNew 连调实例（192.168.50.114:19993）为临时环境——WhatShot 端无任何硬编码地址，正式部署后改 settings.whatsnewBaseURL 即可切换。
- WhatsNew 端 lookup 端点未部署到 NAS 正式环境：WhatShot 生产实例的追剧反查遇 404 **静默降级**（不产 warning、不阻断，部署新版并切地址后自动生效；测试覆盖 lookupWatchlistGracefulWhenEndpointMissing）。

### 建议下一位角色
- WhatsNew 端：无（端点已交付）。WhatsNew 正式部署后由用户触发 WhatShot 端地址切换 + 真实追剧反查验收（或等首轮同步自然验证）。

> 修订 2026-09-23：追加 404 静默降级（生产 NAS 仍为旧版 WhatsNew 时的过渡处理），实现提交 141fa30；全量 117 项测试通过。
