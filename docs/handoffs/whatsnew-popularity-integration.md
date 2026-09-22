# WhatShot 接入 WhatsNew 外部热度：执行交接

## 立即接手

- 交接类型：发送端，设计转执行；下一位角色：WhatShot 执行 agent，完成后交回审查。
- 用户目标：先用现有追剧关注喜欢的作品，再引入 WhatsNew 的其他来源热度作为发现作品的补充。用户认为 butai0 榜单不够准确；不要把本任务替换成给现有榜单加热门标签。
- 授权依据：用户要求“按照你思考的写一个交接给这个项目干活的 agent，让他接入，然后也说清楚实际问题”。已明确接入方向，无需再次询问是否开始 WhatShot 接入；具体界面、协议细节仍可按证据调整。
- 当前状态：**已实现并本机交付（2026-09-22 执行回执见文末）**。真实 WhatsNew 服务联调仍未验证（无可用服务地址）。
- 第一步：核对两仓库状态与规则，确定实际可用的 WhatsNew API、身份字段和数据覆盖；随后在 WhatShot 更新需求、实现可选接入、验证并打包。
- 建议完成标准：用户可配置自己的 WhatsNew 服务，在 WhatShot 查看有来源和时间的外部榜单信号；可靠匹配时关联本地作品，离线不影响追剧与原同步。真实覆盖与未匹配项如实交回，不能以模拟响应代替真实联调成功。

## 定位、状态与必读

快照日期：2026-09-22。下文无前缀路径相对 WhatShot 根目录；`../whatsnew/` 相对同一根目录。

| 仓库 | 当前机器定位 | 分支 / HEAD | 写本文前工作区 |
|---|---|---|---|
| WhatShot | `/Users/zaynzhu/code/claude code/project/whatshot` | `main` / `bae76157787d4e329255002bfe2496b58fe99fe1` | 干净 |
| WhatsNew | `/Users/zaynzhu/code/claude code/project/whatsnew` | `codex/whatsnew-mvp` / `57c003539293a99b0d76068951ed4a48a082b88f` | 干净 |

接手时重新核对；不要把上述 HEAD 当成 NAS 已部署版本。本文为本轮唯一新增文件。

必要阅读顺序：

1. `AGENTS.md`、`CLAUDE.md`：本项目规则，两者本次比对一致；`../whatsnew/AGENTS.md`：服务端规则与安全边界。
2. `docs/requirements.md`：单源热度约束、纯本地方案、定案七追剧与更新汇总。实施前记录本次可选外部热度的明确例外。
3. `../whatsnew/docs/integration-guide.md`、`../whatsnew/backend/src/routes/trending.ts`、`../whatsnew/backend/src/routes/media.ts`：现有 API 的实际能力与截断条件。
4. `../whatsnew/backend/prisma/schema.prisma`、`../whatsnew/backend/src/domain/popularityMovement.ts`、`../whatsnew/CONTEXT.md`：身份、榜单、季版本与 Heat 的含义。
5. `macos/Sources/WhatShotCore/Networking/ButaiSettings.swift`、`Sync/SyncEngine.swift`、`Persistence/Database.swift`、`Persistence/VideoRepository.swift`（后三者同属 `macos/Sources/WhatShotCore/`）：配置、限频、持久化和同步接入点。
6. `macos/Sources/WhatShotApp/App/` 下 `SettingsTabView.swift`、`AppModel.swift`、`DetailSheet.swift`、`WatchlistTabView.swift`、`ContentView.swift`：配置入口、作品关联和展示位置。
7. `scripts/test-macos.sh`、`scripts/build-macos-app.sh`：测试和本机交付。

`docs/whatsnew-reuse-assessment.md` 是早期思路复用评估，不是本次 API 接入规格；`docs/handoffs/project-improvements.md` 的旧“尚未实施”段落不能用来否定已落地的追剧功能。

## 决定、建议与修改边界

| 内容 | 状态与依据 | 接手方式 |
|---|---|---|
| 先使用追剧保留喜欢的作品 | 用户已确认，本轮原话 | 保留现有追剧，不重新设计关注系统 |
| 接入 WhatsNew 热度 API | 用户已确认，本轮要求执行交接 | 实施 WhatShot 可选接入 |
| 展示可解释的来源榜单，不混成统一真实排名 | 既有两项目规则；本轮模型建议沿用 | 保留来源、范围、地区、窗口、采集时间与季版本 |
| 先验证追剧覆盖，再确定展示价值 | 模型建议，用户要求按上述思路交接 | 属于实施第一步，不把它变成只写评估不接入 |
| 可选配置、本地缓存、NAS 离线仍可追剧 | 模型建议 | 作为最小方案，调整须说明依据 |
| API 地址、部署版本、启用来源、实际覆盖 | 未知 | 接手时核对；没有地址时可先实现模拟服务测试，真实联调保持未验证 |
| 新增按稳定外部 ID 批量查询的接口 | 条件性建议，现有接口不足时采用 | 不虚构为已有 API，也不预先建设完整服务层 |

**规则差异需明确处理：** WhatShot 现行规则限定单源热度、无后端依赖。本轮用户接入要求构成“可选读取用户自有 WhatsNew 热度”的范围扩展，执行端先在 requirements 记录，再最小同步 AGENTS/CLAUDE；原 butai0 排名、评分与集数口径仍保留，不做跨源混算，不把整个应用改成 NAS 客户端。

**跨项目写入边界：** WhatShot 规则仍明确禁止修改 `../whatsnew`。本轮明确要求给 WhatShot agent 接入，未明确撤销该跨仓库禁令。可以只读参考和消费已有 API；若必须新增服务端接口，先完成客户端可独立实施的部分并交回具体协议与服务端改动范围，再由获 WhatsNew 修改授权的 agent 执行。仅在确实需要跨仓库写入时解决该授权差异，不要为已有 API 的消费增加确认关卡，也不要把缺失的服务端能力宣称为已完成。

本轮不做：资源搜索、全量拉库、标题模糊匹配、综合推荐算法、系统通知、NAS 数据迁移、自动开启 WhatsNew 来源或调度、公网开放管理接口。生成本文不启动其他 agent。接收端按用户授权与项目规则提交原子变更；不自动推送、发布或部署 NAS。

## 已确认的 API 能力及实际问题

### 1. 已有 API，但返回范围不是完整作品库

- `GET /api/health`：文档约定返回服务标识 `whatsnew-backend` 与环境信息；客户端应验证服务身份，不能把 HTML、错误服务或沙盒当成功。
- `GET /api/trending`：无信号级筛选时先按 `heatScore` 选最多 50 部活跃作品，再返回它们全部当前信号，故信号条数可能大于 50。
- 有 `source/platform/region/window/rankingScope/movement` 任一筛选时，改为最多 50 条匹配信号；仅 `mediaType/releaseForm` 不触发这个分支。
- `GET /api/media/:id`：使用 WhatsNew 内部 ID，返回作品、来源引用、当前评分与热度信号等。
- `GET /api/media/:id/popularity-history`：已有历史接口，默认 30 天，支持 1–90 天。初版不必做趋势图。
- `GET /api/media`：支持文字查询和排序，最多 100 条，当前 `nextCursor` 为 null；不能假定它可以翻页拉全库，也不是按 IMDb/豆瓣 ID 精确查询接口。

**后果：** trending 中没出现某部追剧作品，只能解释为“本次返回范围未覆盖”，不能解释为“不热门”“已下榜”或“WhatsNew 没有这部作品”。初版可直接用现有接口做外部热门发现；若要给任意追剧作品准确补信号，可能需要批量身份查询。

### 2. Heat 不等于更准确的热度

代码 `heatFromCurrentSignals` 取有效信号中最大的 `max(0, 101 - rank)`。它是排序启发值，不是跨平台观众人数或经过校准的综合分数。豆瓣 `douban_top`、`douban_upcoming`、`douban_upcoming_hot` 不参与该分数。

建议展示“来源 + 具体榜单 + 第几名”，例如 Netflix 的具体分类周榜；不同来源名次不得排成伪装的统一总榜。预约、待播、口碑与动态热度含义不同，必须区别呈现或初版只选择适合在播发现的动态信号。不能因为接口可返回某来源，就宣称 NAS 已启用且有新鲜数据。

### 3. 稳定身份并不天然齐全

- WhatsNew `MediaItem` 有 IMDb/TMDb 等字段，没有顶层 `doubanId`；豆瓣身份需核对 `MediaSourceRef` 的实际 `source/sourceId` 写入方式。
- trending 内嵌作品标量字段，但没有把 `sourceRefs` 一并返回，不能假定已有豆瓣 ID 可直接拿来匹配。
- WhatShot 已保存 IMDb 与豆瓣身份；逐条核对格式、有效性、作品大类。电影与剧集绝不互匹配；两个稳定 ID 指向冲突作品时不擅自选一个。
- 不用片名相似度填补缺口。没有可靠身份时显示未关联，可保留外部榜单条目；不得自动写成新的 butai0 作品或自动加入追剧。

### 4. 系列、季与榜单席位需要分开

WhatsNew 的作品可能按系列归并，`Release.seasonNumber` 和热度信号的 `rankingEntryKey/rankingEntryLabel` 承载季/版本信息；标签不保证总能解析出可靠季号。WhatShot 条目可能对应具体季。

同一系列 IMDb 命中只证明系列关系，不自动证明该季上榜。有可靠季依据才展示该季信号；否则明确“系列热度”或保持未关联，不能借助无依据的标题解析猜季。一个作品同榜多季不能按作品 ID 去重覆盖合法席位。

### 5. 新鲜度与请求成功不是一回事

`isCurrent=true` 不保证刚更新；来源停更时也可能存在旧信号。保留 `capturedAt`，有条件时结合来源健康信息；客户端成功取到响应的时间不能冒充榜单更新时间。

区分未配置、首次未取得数据、正常、旧缓存、服务不可达、未覆盖/未匹配、确实无当前信号。失败或不完整响应保留上次有效缓存并显示状态，不清空后制造“全部下榜”。旧数据失效策略要按榜单窗口明确，不预设所有来源同一天数。

### 6. 连接和隐私边界

服务只面向可信内网；现有设置 API 无身份认证，不为此暴露整套服务到公网。WhatShot 保留原 ATS 边界，不增加公网 HTTP 豁免；实际局域网 HTTP 连接须以打包 App 联调为准。

地址仅本地保存，不硬编码个人端点，不在日志打印地址、代理、凭据或追剧清单。外部请求复用统一限频，同一服务间隔至少 2 秒，有限批量、可取消，不逐卡片触发请求风暴。

现有 trending 拉取不需要发送追剧清单。若后续按 ID 查询用户自有 NAS，只传必要媒体身份，不传关注时间、观看状态或完整本地记录，并在需求中记录这项最小数据流。API 读取不得顺带触发来源同步、修改设置或直接写服务端数据库。

## 建议实施步骤与验收

1. **核对实际覆盖。** 使用已配置或用户提供的可信服务地址，只读健康和样本；有追剧样本时统计总数、具备稳定 ID 数、返回范围命中数、精确作品/季匹配数、冲突或无法判断数、新鲜信号数。不在交回文档逐条公开私人清单。若用户尚未关注作品，不等其填满再开工，用测试夹具推进并标注真实覆盖待验。
2. **定最小接入面并记录需求。** 建议独立“外部热度”视图/分区保留来源榜单，通过可靠匹配进入本地详情并沿用关注操作；原热门榜不替换，默认首播排序不变。匹配成功的详情可展示外部信号。界面位置由执行端依据现有布局选择，不必同时实现多个入口。
3. **实现可选客户端、缓存与展示。** 配置关闭或未配置时不发请求；使用明确字段解码和最小持久化。请求在现有低频同步或明确刷新动作中执行，失败不阻塞主同步和追剧。榜单缓存按成功响应的明确范围更新，不因截断响应推断全库删除。身份关联与季映射需可测试。
4. **必要时交回服务端接口需求。** 建议有限批量接收媒体大类和 IMDb/豆瓣 ID，逐项返回 matched/unmatched/ambiguous、匹配依据、作用于系列还是季、来源原生信号与采集时间。未覆盖、无信号和请求失败要分开；批量上限、契约版本、完整性与新鲜度字段写成具体约定。端点名字和结构是建议，不是已存在事实。新增接口应只读数据库、不触发抓取；由获准修改 WhatsNew 的执行者落地。
5. **验证与本机交付。** 先运行针对性测试，再运行 `./scripts/test-macos.sh`，最后 `./scripts/build-macos-app.sh`。在打包 App 核对配置、榜单来源、匹配详情和离线提示。若 API/权限/网络不具备，记录精确未验项，不能写端到端完成。

建议测试至少覆盖：

- 精确 IMDb 命中、豆瓣身份缺失、双 ID 冲突、同名不同作品、电影/剧集隔离。
- 同系列不同季、多季同榜席位、只有系列身份时不冒充季热度。
- 不同来源/地区/窗口的名次不混算，预约/口碑不误标动态热度。
- 超时、错误服务、畸形响应、过期数据、首次无缓存、关闭配置零请求。
- trending 截断与未覆盖不被误判为下榜；不完整响应不破坏已有缓存。
- 缓存迁移、取消和重复同步，不破坏关注记录、已有观察历史与原同步。

若需修改 WhatsNew，服务端测试与构建按该项目规则执行；本文件不授权先改后补批准。

## 打包问题与现有验证证据

本轮先前已确认：用户看不到搜索/追剧等新功能，是本机找到的 `dist/WhatShot.app` 二进制停在 2026-09-19，而功能提交在 09-20。当前会话已在上述 WhatShot HEAD 执行 `./scripts/build-macos-app.sh`，release 构建与签名校验成功，并调用 `open dist/WhatShot.app`；有一条 AppModel 的冗余 await 编译警告，没有修改源码。

当时 `/Applications/WhatShot.app` 和 `~/Applications/WhatShot.app` 均不存在，Spotlight 只找到项目 dist 包。没有确认用户旧入口的真实目标，也没有验证打开后的交互。执行端不能只交付源码：完成后提供新包绝对路径，核对用户实际启动的版本。按项目规则只生成本机 dist 包，不做 DMG、上传或 Release；安装或替换其他位置按当时用户要求处理。

本交接生成阶段没有运行测试，没有 API 实测，没有读取真实数据库、设置或凭据。先前改进回执记载 8 suite / 81 项通过，属于历史记录，不是本接入的测试结果。现在的技术缺口是运行态地址/版本/覆盖未核对，以及任意作品批量查询能力尚不存在于已读接口中。

## 交回要求与接手约定

1. 先核对当前用户要求、项目位置、规则、分支和工作区；本文是任务快照，不扩大权限。无阻塞就继续实施已授权部分，不例行等待确认。
2. 当前代码与验证证据可修正过时进度，不能据代码推断用户改变目标。模型建议可调整并说明原因；影响已确认边界的冲突只暂停受影响部分，说明差异再请求裁决。
3. 保留无关与归属未知改动；发现其他 agent 在写同一模块时先明确分工，不覆盖、不停止对方。本文按顺序交接，不自动创建或调度 agent。
4. 执行角色可在本项目授权范围内修改、验证；只读接手则只交回问题。真实数据修改、跨仓库写入、安装、推送、部署和发布遵守各自授权，不从交接推导许可。
5. 无本 skill 或指定工具也可按上述步骤使用等价能力；无法验证时如实记录，不能把 mock、代码存在或编译通过写成真实联调通过。
6. 按项目规则，每个独立任务验证后以 `type: 中文描述` 提交。完成或受阻交回：改动与 commit、真实 API 契约、覆盖统计与局限、身份/季匹配规则、数据新鲜度策略、测试结果、打包位置、未验证项、跨项目待办和建议下一位角色（默认只读审查）。
7. 获文档写权限时先读当前版本再更新本文件为实际状态，保留有效决定；仅只读权限时在回复中提供回执。无需逐步回写，不自动生成新任务或推送发布。

## 执行回执（2026-09-22，接手 agent 完成）

**已提交（WhatShot main，分支无推送）**：

| commit | 内容 |
|---|---|
| `8603a83` | feat: WhatsNew 客户端（`WhatsNewClient.swift`：health 验证/trending/detail 三端点、独立 2s 限频、容错解码）、匹配器 `ExternalHeatMatcher`（IMDb/豆瓣精确相等、电影剧集隔离、双 ID 冲突不选、不做标题匹配与季推断）、`ExternalHeatStore` 快照持久化（UNIQUE 席位 upsert、截断不清缓存）、库表 `external_heat`/`external_heat_state`、设置扩展 `whatsnewBaseURL`/`whatsnewEnabled`（可选字段向后兼容旧 settings.json） |
| `2fc9d1d` | feat: SyncEngine 可选步骤（health → trending → IMDb 直连匹配 → ≤10 条 detail 补豆瓣身份 → 二次匹配 → 事务写库；失败只计 warning 不阻断主同步）、AppModel 注入（显式启用+已配置地址才构造客户端，关闭零请求）、"外部热度"标签页（按 source 分组、来源/榜/名次/季标签、站方采集时间与本地发现时间分开展示、匹配条目进详情）、设置卡片、详情浮层"外部热度 · WhatsNew"区块 |
| `ddff75d` | test: 引擎集成测试（URLProtocol stub 模拟服务，`@Suite(.serialized)`——并行测试共享 static stub 状态会交叉污染，已串行化） |
| 本回执所在 commit | 定案八入库 + AGENTS/CLAUDE 最小同步 + 本回执 |

**真实 API 契约（对码核对，与本文"已确认的 API 能力"一节一致）**：health 返回 `{ok, service: "whatsnew-backend", environment}`；trending 无筛选时按 heatScore 选 ≤50 部活跃作品返回全部当前信号（Prisma include 全标量，**内嵌 mediaItem 含 imdbId/tmdbId**，不含 sourceRefs）；detail 才带 `sourceRefs`（豆瓣格式 `source: "douban", sourceId: "douban-<数字>"`）；无批量身份查询端点、`/api/media` 列表不可翻页拉全库。Heat= max(0, 101-rank) 仅排序启发值，豆瓣 top/upcoming 类不参与。

**匹配规则（实现定稿）**：只做稳定 ID 精确相等（IMDb 规范化小写；豆瓣经 `douban-<id>` 提取数字）；mediaType "movie"/"series" 与本地 kind 1/2 兼容映射，其他取值保守不匹配；双 ID 命中不同本地条目 → 不匹配；同系列命中不冒充该季（WhatShot 库内 imdb_number 常为"该季第 1 集"单集 tt 号，与 WhatsNew 作品级 imdbId 不相等 → 如实显示"未关联"，不做标题解析猜季）；多季同榜按 rankingEntryKey 独立席位。

**新鲜度策略（实现定稿）**：`capturedAt` ISO 原样保留与本地 `fetchedAt` 分开展示，客户端取到响应的时间不冒充榜单更新时间；快照表按 UNIQUE upsert 覆盖、不删除未返回行（trending 50 条截断下"未返回"≠下榜），不预设施来源过期天数（初版不做自动失效，展示原文由用户判断）。

**验证**：全量 `./scripts/test-macos.sh` 102 项（10 套）通过——含新增单元 17 项（解码/匹配含双 ID 冲突与电影剧集隔离/持久化幂等与截断保缓存/状态机）+ 引擎集成 4 项（stub 模拟服务：成功链路 2 请求全链、bad_service 拒接、unreachable 保留缓存与上次成功时间、畸形响应记状态）。**模拟 stub 是集成验证手段，不能替代真实联调**。**真实联调已完成（2026-09-22，用户自有 NAS `http://192.168.50.233:50016`，用户当轮提供）**：
- health 实测 `{ok: true, service: "whatsnew-backend", environment: "main"}`，服务身份验证通过
- trending 实测 69 信号 / 50 部作品（≤50 截断实证）、44/69 带 imdbId、capturedAt 100% 存在；真实响应顶层键与 mediaItem 键与客户端解码模型 **100% 对齐**
- detail 实测 sourceRefs 格式多样（`imdb:tt...` / `thetvdb:movie:` / `tmdb-movie-`），豆瓣 ref 为 `douban-<id>`；部分作品无 douban ref（iqiyi/tencent/bilibili 抽样 4 部无身份，如实未关联）
- **匹配覆盖实测**：IMDb 路径 0/28 命中（库内 180 条有 imdb_number）——双重原因：① WhatShot 活跃范围以国剧/番剧为主，与 WhatsNew trending 的欧美 Netflix/Trakt 内容交集小；② **tt 号层级错位**（库内为"该季第 1 集"单集 tt 号 vs WhatsNew 作品级 tt 号）。**豆瓣路径真实命中**：youku_reserve 抽样 2/2 命中（蜘蛛侠：崭新之日 93980、一瓯春 94026，`douban-<id>` ↔ 库内 douban_id 精确相等）；bilibili 番剧无身份无法匹配
- **live 全链路测试通过**（真实服务 × 真实客户端代码 × 临时库：69 条信号全解码入库、豆瓣匹配命中、状态 ok，22.9s 含真实 2s 限频）——测试文件跑完即删，不留在套件中依赖外部服务

**打包**：`/Users/zaynzhu/code/claude code/project/whatshot/dist/WhatShot.app`（ad-hoc 签名，arm64 thin，含全部接入代码；测试文件不入产物）。AppModel 冗余 await 警告为既有（本文档 120 行已记，未改源码）。

**未验证项（如实）**：
1. ~~真实 WhatsNew 服务联调未做~~ → **已完成**（见上验证节）。
2. （原第 2 条已并入联调结果：detail 补查路径已在真实响应上实测）（19993/19992 均未监听，仅有 WhatsNew.app 客户端进程，其文档声明不跑本地服务）；用户 NAS 实际地址与部署版本未提供。覆盖统计（追剧命中率、未匹配比例、来源清单）待用户在设置中配置真实地址后首轮同步核对。
2. detail 补豆瓣身份的 detail 补查路径真实响应未实测（stub 验证了容错分支）。
3. App 内端到端交互（配置→同步→外部热度页展示→详情关联）未人工走查——建议用户装新包后自查；局域网 HTTP 连接以打包 App 实测为准（ATS 边界未新增豁免，仅既有 NSAllowsLocalNetworking）。

**跨项目待办（需 WhatsNew 修改授权，本轮未动 `../whatsnew`）**：如需给任意追剧作品准确补信号（trending 50 条截断外的），建议 WhatsNew 新增有限批量按 IMDb/豆瓣 ID 查询端点，逐项返回 matched/unmatched/ambiguous 与匹配依据——协议细节见本文"必要时交回服务端接口需求"一节，由获 WhatsNew 授权的 agent 落地。

**建议下一位角色**：只读审查（审查上述实现与测试、真实联调后的覆盖核对）。配置入口：设置 → "外部热度（WhatsNew）"卡片，开关 + 地址（如 `http://<NAS-IP>:19993`）。
