# WhatShot 项目规则

## 项目定位

WhatShot 是独立的播出影视热度与播出进度（更新至第 X 集）追踪应用。参考站 https://www.butai0.club/ 的公开 JSON 接口为一期主数据源。**首播日与海报各有收窄的补全源**（剧集页首播排序与海报展示依赖）：① 豆瓣 rexxar 接口按库内 douban_id 直连，补首播日（取值口径"全都要取最早"）与海报（`pic.large`，`/tv/` 404 回退 `/movie/`）；② TMDB 兜底——给有 IMDb 号的条目补**该季**首播日（不是系列 first_air_date）与海报（`/find` 按 imdb_id 直连不标题搜索）。两者都只补空/坏值不覆盖豆瓣已写日期与站方好 URL。两个源都不得做标题搜索、不补评分/简介/逐集，机制细节见 docs/requirements.md 定案二/五/六。**WhatSew 参考项目（`../whatsnew`）只作架构参考，不得改动。**

一期明确不做：资源搜索（二期）、NAS 后端（架构仍为纯本地——S3 镜像桶是哑存储例外，见下）、多源热度叠加（二期）。

## 海报与 S3 镜像（2026-09-18 定案六）

- **站方图床不可信**：butai0 挂过 `http://localhost:3000` 事故 URL，2026-09-18 起图床整体迁移 `img.mvinfo.homes` 且只有明文 http——**App 一律不请求站方 http 图床**（macOS ATS 红线，不豁免任何第三方域）
- **海报兜底**：`poster_url` 为空/localhost/http 的条目，有 IMDb 走 TMDB、其余走豆瓣；写库只补坏 URL，`upsert` 的 CASE 防"站方把好 URL 改写回坏值"回滚
- **S3 镜像**（可选，四项配置齐全才启用）：兜底取到的外源图先镜像进用户自有 S3 兼容桶（RustFS/MinIO，path-style + SigV4），`poster_url` 写桶 URL；桶暂不可达降级直写外源 URL。凭据只存本地 settings.json，不进 git
- **ATS 唯一豁免**：打包脚本 Info.plist 注入 `NSAllowsLocalNetworking`（仅放行局域网私有 IP/.local），不得扩大到任何公网域

## 目录与职责

- `macos/`：Swift Package，`WhatShotCore`（模型、网络、持久化、同步）+ `WhatShotApp`（SwiftUI 窗口应用）+ Core 测试
- `scripts/`：测试与本地 ad-hoc 打包脚本
- `docs/requirements.md`：需求、butai0 接口调研结论与已确认决策，改需求先改这里

## 架构定案（2026-09-11）

- **方案 A 纯本地应用**：无 NAS、无后端服务、无 MySQL；本地 SQLite（系统 sqlite3 C 库，不引入 GRDB 等第三方依赖）
- 普通窗口应用形态（WindowGroup；MenuBarExtra/NSStatusItem 在本机 macOS 26 上状态项不可见，已验证放弃），macOS 14+，Swift 6 工具链，不嵌 WebView

## 硬性资源约束（8GB Mac mini）

- 空闲内存 < 60MB（实测 15MB）：分页懒加载、不一次性载入全量数据、海报内存用 NSCache
- 海报磁盘缓存设上限（默认 300MB，可调低/关闭，**关闭 = 不读不写磁盘仅内存**，2026-09-20 定案），LRU 淘汰
- 平时零定时器空转；同步是低频短促任务（默认 6 小时一次，可手动触发、可关闭）
- SQLite 是单文件，不跑常驻进程

## 数据与同步约束

- 同步范围只做活跃内容：热门榜（近日/本周/本月 `getVideoList?sc=3/4/5`）+ 剧集/电影按更新时间排序的前几页（`getVideoMovieList`）；对 ejs/seed_num/评分变化的条目才补拉 `getVideoDetail`。**追剧检查例外（2026-09-20 定案七）**：每轮同步对追剧条目 detail 刷新上限 20 条、最久未检查优先——离开活跃范围的已关注作品靠它保持更新，这是"只做活跃内容"的显式例外而非违规
- 禁止全量拉取 2.5 万条库
- 每个同步周期把 ejs、seed_num、评分写入本地历史表，保留"9 集→10 集"进度时间线
- **榜单批次写入必须原子**（`upsertBatch`：一个榜单/一页一个事务、整批共享同一观察时间戳、失败整批回滚不替换旧榜；latestChart 按 MAX(observed_at) 单秒切片依赖此约束）；名次变化只比较同 scope 相邻两个已提交批次，首次同步不制造入榜事件
- 热度口径仅 butai0 单源：热门榜 + seed_num + 豆瓣/IMDb 评分；**保留来源、榜单范围与时间窗口，不跨源混算排名**；seed_num 是站内信号，不是客观热度
- 外部请求统一限频，同一站点连续请求间隔不低于 2 秒
- 站点域名做池化择优（`DomainPool.swift`：同步前从发布页 butailing.com 自动发现官方域名，内置兜底池仅在发布页不可达时使用；用户自定义最高优先、探活选路、连续失败自动降级，机制细节见 docs/requirements.md）；接口解析必须容错，字段缺失不报错；`ejs`(更新至X集/全集/空)、`episodes`(总集数, "0"=未知)、`seed_num`/`wp_num`、`doub_id`/`IMDB_number` 等字段语义见 docs/requirements.md
- 种子/网盘列表需 VIP，一期不得依赖 `all_seeds` 等数据
- seed_num/wp_num 库内继续记录但**不在界面展示**（2026-09-13 用户定案）；同步状态、错误只展示给用户，不把凭据/接口参数打进日志

## 安全红线

- 不记录、不上传用户设置中的域名与代理值到任何外部服务
- 数据只存本地（Application Support + Caches），不上传

## Git

- Commit 使用 `type: 中文描述`，每次只提交一个独立变更
- 打包只生成本机 `dist/WhatShot.app`（ad-hoc 签名），不做 DMG、不上传产物、不创建 GitHub Release