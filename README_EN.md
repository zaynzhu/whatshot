<div align="center">

<img src="docs/logo.png" alt="WhatShot Logo" width="200"/>

# 🔥 WhatShot

**Track the heat and episode progress of released shows and movies — at a glance**

[中文](README.md) | [English](README_EN.md)

[![Platform](https://img.shields.io/badge/platform-macOS%2014+-black)](https://github.com/zaynzhu/whatshot)
[![Language](https://img.shields.io/badge/language-Swift-orange)](https://github.com/zaynzhu/whatshot)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/zaynzhu/whatshot?style=social)](https://github.com/zaynzhu/whatshot/stargazers)
[![Last Commit](https://img.shields.io/github/last-commit/zaynzhu/whatshot)](https://github.com/zaynzhu/whatshot/commits)
[![Issues](https://img.shields.io/github/issues/zaynzhu/whatshot)](https://github.com/zaynzhu/whatshot/issues)

</div>

> [!TIP]
> WhatShot is a **fully local** macOS app focused on two questions: is a show or movie **hot right now** (charts, ratings), and **how far along is it** (up to episode X / Y total / completed, ordered by premiere date). No backend, no account, no data leaving your machine.

## ✨ Features

- **Three chart windows** -- Recent / weekly / monthly hot charts, with a hero card for the #1 title; each chart shows its own last-updated time and refresh status, plus per-card rank movement badges (NEW / up / down)
- **Episode progress tracking** -- "Up to episode 9", "24 total", "Completed" as a dedicated info row with a visual progress line
- **Series & movie galleries** -- Browse recently updated titles in a poster-wall grid with adaptive layout
- **Premiere timeline** -- Series sorted by premiere date (re-seeded classics no longer surface), with year / status / genre / region filters and a detail sheet (synopsis, cast, episode-progress log, Douban / IMDb links). **Dual-source premiere backfill**: Douban fills premiere dates via existing douban_id (no key needed); when Douban is rate-limited, an optional TMDB fallback fills the per-season premiere date for Western series that have an IMDb ID (never overwrites a Douban-written date; requires a TMDB Bearer Token in Settings)
- **Douban / IMDb ratings** -- Aggregated rating signals per card in monospaced digits
- **Lightweight resident footprint** -- ~15MB idle memory, single-file SQLite, tunable poster cache, zero idle timers
- **Low-frequency auto sync** -- A short sync every 6 hours by default (~10–20 requests per run), manual trigger or off
- **Transparent sync status** -- The header status distinguishes "synced / partially completed / failed" and ages over time; click to expand a per-step breakdown (per-chart and backfill results, error details and retry notes) — minor hiccups like Douban rate-limiting no longer masquerade as failures
- **Data-source resilience** -- domains auto-discovered from the publish page (with a built-in fallback pool), probe-based auto-selection, instant failover on errors, tolerant field parsing, placeholder-poster interception
- **Late-night gallery design** -- Dark monochrome-amber visual language, editorial typography, pure native SwiftUI

## 🚀 Quick Start

```bash
git clone https://github.com/zaynzhu/whatshot.git
cd whatshot
./scripts/build-macos-app.sh
open dist/WhatShot.app
```

On first launch, click "同步" (Sync) in the top-right corner to pull the charts and recent updates.

> [!NOTE]
> Requires macOS 14+ and Xcode Command Line Tools (Swift 6 toolchain). The app is ad-hoc signed; if Gatekeeper blocks the first launch, right-click → Open.

## 📦 Installation

**Option 1: build script (recommended)**

```bash
./scripts/build-macos-app.sh   # produces dist/WhatShot.app (ad-hoc signed)
```

**Option 2: SwiftPM manually**

```bash
swift build --package-path macos --configuration release
# binary at macos/.build/release/WhatShotApp
```

**Run tests**

```bash
./scripts/test-macos.sh   # Swift Testing, 32 tests
```

Dependencies: zero third-party — system `sqlite3` C library for storage, `URLSession` for networking, native SwiftUI for UI.

## 💡 Usage

**Browse the charts**

The app opens on the "热门榜" (Charts) tab: switch between recent / weekly / monthly. On wide windows the #1 title gets a hero card (rank, title, episode progress, ratings, synopsis and a progress line); the rest flow in a gallery grid. The header subtitle shows when this chart's data was last refreshed; if a chart failed this round it says "showing previous data" instead. Rank movement badges (NEW / ↑n / ↓n) compare two consecutive complete sync batches — the very first sync never flags everything as new.

**Follow series updates**

Switch to the "剧集" (Series) tab, sorted by **premiere date** by default (switchable to resource-update time). Cards show the title, up-to-episode status (amber = ongoing), premiere date and Douban / IMDb ratings; the filter rail offers year / airing status / genre / region; click a card for the detail sheet (synopsis, cast, episode-progress log, external links); scroll to the bottom to lazy-load more.

**Tune sync & cache**

The "设置" (Settings) tab lets you optionally pin a custom domain (highest priority when set; leave empty to use the official domain pool — each sync first discovers the latest domains from the publish page, then probes and picks the fastest official route, failing over automatically), tune sync frequency and the poster cache limit (300MB by default, lower or off), and shows the current route with measured latency and disk usage.

## 📚 Documentation

| Doc | Description |
|-----|-------------|
| [docs/requirements.md](docs/requirements.md) | Confirmed requirements, butai0 API research (field semantics, pitfalls), architecture decisions |
| [AGENTS.md](AGENTS.md) | Project rules: layout, resource constraints, security red lines |

## 🤝 Contributing

Issues and PRs welcome:

1. Fork the repo and create a branch (`git checkout -b feat/your-feature`)
2. Commit messages follow `type: 中文描述` (e.g. `feat: 添加批量同步`)
3. Run `./scripts/test-macos.sh` and make sure tests pass
4. Open a Pull Request

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=zaynzhu/whatshot&type=Date)](https://star-history.com/#zaynzhu/whatshot&Date)

## 📄 License

Released under the [MIT License](LICENSE).