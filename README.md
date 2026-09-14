<div align="center">

<img src="docs/logo.png" alt="WhatShot Logo" width="200"/>

# 🔥 WhatShot

**追踪已播出影视的热度与更新进度 —— 更新至第 X 集，一目了然**

[中文](README.md) | [English](README_EN.md)

[![Platform](https://img.shields.io/badge/platform-macOS%2014+-black)](https://github.com/zaynzhu/whatshot)
[![Language](https://img.shields.io/badge/language-Swift-orange)](https://github.com/zaynzhu/whatshot)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/zaynzhu/whatshot?style=social)](https://github.com/zaynzhu/whatshot/stargazers)
[![Last Commit](https://img.shields.io/github/last-commit/zaynzhu/whatshot)](https://github.com/zaynzhu/whatshot/commits)
[![Issues](https://img.shields.io/github/issues/zaynzhu/whatshot)](https://github.com/zaynzhu/whatshot/issues)

</div>

> [!TIP]
> WhatShot 是一款**纯本地**的 macOS 窗口应用，专注两个问题：某部剧/电影现在**热不热**（热门榜、评分），以及某部剧**更新到第几集**（更新至 X 集 / 共 Y 集 / 全集完结，按首播日期倒序的时间线）。无后端、无账号、数据不出本机。

## ✨ Features

- **热门榜三窗口** -- 近日 / 本周 / 本月热门影视榜，榜首以 hero 大卡呈现，一眼看到当下最热；每榜独立标注数据更新时间与刷新状态，卡片带名次变化标记（NEW / 升 / 降）
- **播出进度追踪** -- 「更新至 9 集」「共 24 集」「全集完结」独立信息行，进度线可视化追剧进度
- **剧集 / 电影双分类画廊** -- 海报墙式浏览最近更新的剧集与电影，窗口自适应布局
- **首播时间线** -- 剧集按豆瓣首播日期倒序排列（老剧重供不再冒头），配套年代/状态/类型/地区本地筛选与详情浮层（简介、演职员、集数推进记录、豆瓣/IMDb 外链）
- **豆瓣 / IMDb 双评分** -- 每张卡片聚合评分信号，等宽数字排版
- **低资源常驻** -- 空闲内存约 15MB，SQLite 单文件存储，海报缓存上限可调，平时零定时器空转
- **低频自动同步** -- 默认 6 小时一次短促同步（每轮约 10~20 个请求），可手动触发、可关闭
- **数据源韧性** -- 发布页域名自动发现 + 兜底池探活择优、失败秒级降级换路由、接口字段容错解析、失效海报占位图自动拦截
- **深夜画廊设计** -- 深底单色琥珀视觉语言，杂志式排版层级，原生 SwiftUI 零依赖

## 🚀 Quick Start

```bash
git clone https://github.com/zaynzhu/whatshot.git
cd whatshot
./scripts/build-macos-app.sh
open dist/WhatShot.app
```

首次打开点击右上角「同步」拉取热门榜与最近更新，之后即可浏览。

> [!NOTE]
> 需要 macOS 14+ 与 Xcode Command Line Tools（Swift 6 工具链）。应用为 ad-hoc 签名，首次打开如遇 Gatekeeper 拦截，右键 → 打开即可。

## 📦 Installation

**方式一：脚本打包（推荐）**

```bash
./scripts/build-macos-app.sh   # 产出 dist/WhatShot.app（ad-hoc 签名）
```

**方式二：SwiftPM 手动构建**

```bash
swift build --package-path macos --configuration release
# 产物在 macos/.build/release/WhatShotApp
```

**运行测试**

```bash
./scripts/test-macos.sh   # Swift Testing，32 个测试
```

依赖清单：零第三方依赖 —— 本地存储用系统 `sqlite3` C 库，网络用 `URLSession`，UI 用原生 SwiftUI。

## 💡 Usage

**浏览热门榜**

启动应用默认进入「热门榜」标签：近日 / 本周 / 本月三个榜单切换，窗口足够宽时榜首以 hero 大卡展示（名次、标题、播出进度、评分、简介与进度线），其余条目按画廊网格排布。页头副标显示该榜数据最后更新时间；某榜本轮刷新失败时提示"显示上次数据"，不与成功榜混淆。卡片名次旁的变化标记（NEW / ↑n / ↓n）由相邻两次完整同步批次比较得出，首次同步不会误标全部为新入榜。

**追剧集更新**

切到「剧集」标签，默认按**首播日期倒序**浏览（可切回资源更新排序）。卡片显示片名、更新至 X 集（琥珀色进行中信号）、首播日期与豆瓣 / IMDb 评分；页头筛选条支持年代 / 播出状态 / 类型 / 地区四维筛选；点击卡片弹出详情（简介、演职员、集数推进记录、豆瓣 / IMDb 外链）；滚动到底部自动懒加载更多。

**调整同步与缓存**

「设置」标签可自定义数据源域名（可选，最高优先；留空则自动使用官方域名池——同步前先从发布页 butailing.com 自动发现最新域名，再探活选当前最快的官方路由，故障自动切换），同步频率与海报缓存上限（默认 300MB，可调低或关闭），并显示当前路由与实测延迟、磁盘占用。

## 📚 Documentation

| 文档 | 说明 |
|------|------|
| [docs/requirements.md](docs/requirements.md) | 需求定案、butai0 接口调研结论（字段语义、坑点）、架构决策 |
| [AGENTS.md](AGENTS.md) | 项目规则：目录职责、资源约束、安全红线 |

## 🤝 Contributing

欢迎 Issue 与 PR：

1. Fork 本仓库并新建分支（`git checkout -b feat/your-feature`）
2. 提交遵循 `type: 中文描述` 格式（如 `feat: 添加批量同步`）
3. 运行 `./scripts/test-macos.sh` 确认测试通过
4. 发起 Pull Request

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=zaynzhu/whatshot&type=Date)](https://star-history.com/#zaynzhu/whatshot&Date)

## 📄 License

本项目基于 [MIT License](LICENSE) 开源。