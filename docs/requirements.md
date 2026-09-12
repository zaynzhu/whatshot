# WhatShot 一期需求与架构（已确认）

> 状态：一期（方案 A 纯本地应用）已开发完成并推送到 https://github.com/zaynzhu/whatshot.git 。架构于 2026-09-11 确认；2026-09-12 UI 重设计定稿：「深夜画廊·档案版」——深底 #101013 + 单色琥珀 #D9A441 + eyebrow/粗标题杂志层级 + 榜首 hero 位，参考 re0.me 与 whatsnew 的家族审美（替代旧的深色影院海报墙主题）；同日完成琥珀火焰应用图标与两处数据源韧性修复（图床占位图拦截、分类以拉取来源为准）。本文档为需求与接口调研的定案依据。

## 项目定位

WhatShot 聚焦**已播出影视的热度与播出进度**：

- 核心问题一：某部剧/电影现在热不热（热门榜、资源数、评分）
- 核心问题二：某部剧现在更新到第几集（更新至 X 集 / 共 Y 集 / 全集完结）
- 一期不做：资源搜索接入（二期）
- 交付形态：类似 WhatsNew 的 macOS 应用（dmg 本地打包，不做签名公证）

参考项目 WhatsNew（`../whatsnew`）只作为架构与规范参考，不作为代码基底，**不得改动**。

## 参考站 butai0.club 调研结论（2026-09-11 实测）

### 站点性质

- Vue SPA，HTML 是空壳，数据全部来自 JSON 接口
- 无需登录即可获取核心数据；种子/网盘**列表**需 VIP（`need_vip:1`），但卡片级数据不受影响
- 站点自身声明了多个备用域名（butailing.com、0bt0~9bt0.com 等），**域名会变，必须可配置**
- **域名池自动择优（2026-09-12 实测定案）**：全部 12 个官方域名（butai0.club/butai0.com/0bt0~9bt0.com）是同一数据库的不同 CDN 路由，接口内容逐条一致（整包哈希差异仅为 requestId 壳字段）——切换域名零数据风险。应用内置官方池（`DomainPool.swift`，站点整批换域名时升级此数组），同步前 HEAD 真实链路探活择优（冠军记忆：先探上次成功的域名，通了只花一次探活；失败才全池并行取最快）；同步中同域名连续 2 次失败自动降级换域名从失败步骤继续；用户自定义地址进池最高优先，全池不可达才报错。二期可从发布页 https://www.butailing.com/ 自动发现新域名并入池

### 公开 JSON 接口

基址：`https://www.butai0.club/prod/api/v1/`
公开参数：`app_id=83768d9ad4`、`identity=23734adac0301bccdcb107c4aa21f96c`（写死在前端 JS 的固定值，缺失时报 `接口鉴权失败` code 10101）

| 接口 | 用途 | 关键字段 |
|------|------|---------|
| `getVideoList?sc=1/2` | 首页电影/电视剧精选 | 同热门榜 |
| `getVideoList?sc=3/4/5` | 近日/本周/本月热门榜，各 35 条 | `title`、`ejs`、`episodes`、`seed_num`、`wp_num`、`doub_score`、`doub_id`、`IMDB_number`、`IMDB_score`、`definition`、`class`、`production_area`、`years`、`release`、`abstract`、`director`、`performer`、`seed_updated_at`、`updated_at` |
| `getVideoMovieList?sa=1(电影)/2(剧集)&page=N` | 全库列表，total 25124 条，每页 25 条；支持类型/地区/年份/画质/状态(更新中/已完结)/排序(更新时间等)筛选 | 列表版字段：`doub_id`、`id`(内部 ID)、`doub_id`(豆瓣 ID)、`aurl`、`epic`(海报)、`title`、`ejs`(更新至X集/全集/空)、`niandai`(年代)、`ecc`(又名/类型/地区聚合)、`alias`、`class`、`production_area`、`seed_num`、`wp_num`、`imdbf` |
| `getVideoDetail?id=X` | 详情 49 字段 | 列表字段全量 + `otitle`(原题)、`episodes`(总集数)、`language`、`edit`(编剧)、`performer`、`abstract`、`long_time`、`is_show_seed`、`need_vip` |
| `getVideoTypeList` | 类型/地区/画质/标签字典 | 筛选器元数据 |

### 关键字段语义（从页面渲染反推，需保守解析）

- `ejs`：`更新至9集` / `全集` / 空。剧集播出进度；电影通常为空
- `episodes`：总集数字符串，`"0"` 表示未知；`ejs=全集` 时代表已完结
- `seed_num` / `wp_num`：当前种子/网盘资源条数，站内热度信号
- `seed_updated_at`：资源最后更新时间，可判断"是否还在更新"
- `doub_id`：豆瓣 subject ID，可作为稳定外部身份用于后续对账
- `IMDB_number`：tt 开头的 IMDb 编号（详情/热门接口才有）
- 热门接口 `data.data` 双层嵌套；列表接口 `data.list` 单层——两种结构不同，解析必须分开写
- **分类不可信（2026-09-12 实测）**：列表接口行内无 `tp`/`type` 字段，分类必须以拉取来源 `sa` 参数为准；站点「电影页」会混入真剧集（如与萨曼莎·比第四季 `tp=1` 但 `ejs=更新至35集`），且详情接口的 `tp` 与站点归类矛盾——详情回写只补字段，不得覆盖库内分类
- **图床占位图（2026-09-12 实测）**：海报图床对失效 URL 返回 HTTP 200 的白底爆米花占位图（300x420、中心亮度 >0.85），客户端加载时必须拦截并回退应用内占位符，否则会永久缓存

### 反爬与限频

- 直接 `curl` 可访问，无 Cloudflare 拦截；1 秒间隔连发 5 次无限频
- 但适配器仍按全局规范 2 秒限频，保守使用
- 字段是私有接口，随时可能变化：解析必须容错（字段缺失不报错），URL 必须可配置

## 资源约束（2026-09-11 用户要求，硬性）

用户主力机是 8GB Mac mini，应用开机常驻，必须低内存、低磁盘：

- **磁盘**：SQLite 单文件，跟踪活跃作品 + 历史，一年也只几十 MB；海报磁盘缓存设上限（默认 300MB，可调低/关闭），LRU 淘汰，远小于 whatsnew 的 2GB+512MB
- **内存**：空闲内存目标 < 60MB（实测 15MB）；全原生 SwiftUI，不嵌 WebView；列表分页懒加载，不一次性载入全量数据；海报内存用 NSCache（系统压力下自动逐出）
- **CPU**：平时零定时器空转；同步是短促任务（默认低频如 6 小时一次，可手动触发、可关闭后台同步）
- **自启动**：暂未实现（普通窗口应用形态，二期可加 SMAppService 登录项）

## 架构方案（已定：A 纯本地应用）

**2026-09-11 用户拍板：选 A，否决 C（感觉复杂）。**

| 方案 | 结论 |
|------|------|
| A 纯本地应用（已选） | SwiftUI + 本地 SQLite，直接调 butai0，无 NAS 依赖 |
| B 照搬 WhatsNew（未选） | NAS Express 后端 + 数据库 + macOS 客户端，多端共享但开发量翻倍 |
| C 本地优先留接口（被否） | 用户认为复杂 |

**推荐理由**：同步范围已定为活跃内容（每次约 10~20 个请求、一分钟内完成），这种量级用应用内定时同步即可，不需要 NAS 常驻服务；whatsnew 走 NAS 后端是因为多来源多端共享，whatshot 一期单源单机，方案 A 最小可用。

## 同步与热度口径

### 同步范围（已定，2026-09-11 用户确认）

**活跃内容为主，不做全量拉取。** butai0 每天更新，全量 2.5 万条大多是老片，拉取无意义：

1. 热门榜三个（近日/本周/本月，各 35 条）——每次同步固定拉
2. 剧集/电影"按更新时间排序"的前若干页——覆盖在播、在更新的内容
3. 本地对比上一次快照，只对 `ejs` / `seed_num` / 评分变化的条目补拉 `getVideoDetail` 全量字段
4. 每个观察周期把 `ejs`、`seed_num`、评分写入本地历史表，形成"从 9 集更到 10 集"的进度时间线和热度趋势
5. 日常增量同步约 10~20 个请求（2 秒限频下一分钟内完成）；首次冷启动约几百个请求

### 热度口径（一期，建议仅 butai0 单源）

- 热门榜（近日/本周/本月）+ `seed_num` 资源数 + 豆瓣/IMDb 评分
- 沿用 WhatsNew 教训：**保留来源、榜单范围与时间窗口，不做跨源混算排名**；`seed_num` 是站内信号，不是客观热度
- 多源叠加（TMDb/TVmaze）留给二期

## 技术栈基线（与 WhatsNew 对齐的部分）

- SwiftUI + Swift Concurrency + Observation，macOS 14+
- 本地方案 A：SQLite（系统 sqlite3 C 库）做快照，URLSession + 2 秒限频的 HTTP 客户端
- 测试：`scripts/test-macos.sh`；打包：`scripts/build-macos-app.sh`（本地 ad-hoc 签名，只产 `dist/WhatShot.app`，不做 DMG 上传、不做 Release——对齐 WhatsNew 约束）；应用图标由 `scripts/make-appicon.sh` 渲染生成
- 安全：接口参数、域名、代理设置只存本地，不上传；不打日志

## 二期备忘

- 资源搜索接入（种子/磁力/网盘检索）
- 可选多源热度（TMDb/TVmaze 播出信息）
- NAS 后端/多端同步（若选方案 C 且确有需求）
- 二期备忘
  - butai0 详情页 VIP 资源列表不可获取，勿设计依赖该数据的功能
  - 发布页域名自动发现：同步时抓 butailing.com 解析域名列表并入池（替代硬编码默认池的升级路径）