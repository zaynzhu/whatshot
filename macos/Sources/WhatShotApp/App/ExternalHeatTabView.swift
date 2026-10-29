import SwiftUI
import WhatShotCore

/// 外部热度（2026-09-22 WhatsNew 可选接入）：用户自有 WhatsNew 服务的来源榜单展示。
/// 保留来源、榜、窗口与季版本（entry_key 独立席位），不跨源混算排名；
/// 匹配本地条目可进详情，未关联条目保留在榜单里如实显示。
/// 数据来自同步时写入的本地快照——本页零 API 请求（海报走 WhatsNew 代理端点，
/// 服务端自带缓存，懒加载复用 PosterLoader 的 NSCache/磁盘缓存）。
/// 视觉对齐"深夜画廊"：琥珀大号名次 + 海报行 + 杂志层级
struct ExternalHeatTabView: View {
  @Environment(AppModel.self) private var app
  @State private var rows: [ExternalHeatStore.DisplayRow] = []
  @State private var state: ExternalHeatStore.State?
  @State private var loading = false
  @State private var detailTarget: VideoRepository.VideoRow?
  /// 选中的来源榜（nil = 自动选组内最优名次的组）；不同榜单名次不可比，不提供"全部"混排
  @State private var selectedSource: String?
  @State private var upcomingTarget: UpcomingWork?
  @State private var upcomingWorks: [String: UpcomingWork] = [:]
  @State private var upcomingConnections: [String: WorkConnection] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(
        eyebrow: "EXTERNAL HEAT · WHATSNEW",
        title: "外部热度",
        subtitle: subtitle
      ) {
        if app.syncingExternalHeat {
          OutlineButton(title: "停止刷新", icon: "xmark") { app.stopExternalHeat() }
        } else {
          OutlineButton(title: "刷新热度", icon: "arrow.clockwise") { Task { await app.refreshExternalHeat() } }
            .disabled(!configured || app.syncing || app.queue == nil)
            .help(app.syncing ? "主同步正在运行，完成后可独立刷新热度" : "只刷新外部榜单，不等待片库和海报补全")
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 18)

      if app.syncingExternalHeat {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("正在刷新外部榜单…").font(.system(size: 11))
        }.foregroundStyle(Theme.accent).padding(.horizontal, 20).padding(.top, 10)
      } else if configured, let message = app.externalRefreshMessage {
        Text(message).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
          .padding(.horizontal, 20).padding(.top, 10)
      }

      // 错误横条：只在最近一次拉取失败时显示（正常时不占版面）
      if configured, let state, state.lastStatus != "ok", state.lastStatus != "never" {
        errorBanner(state)
          .padding(.horizontal, 20)
          .padding(.top, 12)
      }

      Rectangle()
        .fill(Theme.hairline)
        .frame(height: 1)
        .padding(.top, 14)

      if loading && rows.isEmpty {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        emptyState
        Spacer()
      } else {
        gridSection
      }
    }
    .background(Theme.bg)
    .task(id: "\(app.externalRevision)|\(app.upcomingRevision)|\(app.settings.enabledUpcomingSources)") { await reload(); if selectedSource == nil { selectedSource = app.externalFocus?.source } }
    // 同步完成后刷新（新快照可能带来新信号）
    .onChange(of: app.lastSummary) { _, _ in
      Task { await reload() }
    }
    .sheet(item: $detailTarget) { target in
      DetailSheet(video: target, repo: app.repo)
    }
    .sheet(item: $upcomingTarget) { target in
      UpcomingDetailSheet(row: target, connection: upcomingConnections[target.id] ?? .empty)
    }
  }

  // MARK: - 状态与空态

  private var enabled: Bool {
    app.settings.whatsnewEnabled == true
  }

  private var configured: Bool {
    enabled && !(app.settings.whatsnewBaseURL ?? "").isEmpty
  }

  /// 头部副题：如实区分未配置/失败/正常，不把"请求成功"冒充"数据新鲜"
  private var subtitle: String {
    guard configured else { return "在设置中配置你的 WhatsNew 服务地址后启用" }
    if let state, state.lastStatus == "ok" {
      var parts: [String] = []
      if let mediaCount = state.lastMediaCount {
        parts.append("覆盖 \(mediaCount) 部作品")
      }
      if let fetched = state.lastSuccessAt {
        parts.append("更新于 \(ContentView.relativeTime(fetched))")
      }
      return parts.isEmpty ? "榜单随同步更新，数据来自你的 WhatsNew 服务" : parts.joined(separator: " · ")
    }
    if let state, state.lastStatus != "never" {
      return state.statusText + "，下轮同步自动重试"
    }
    return "已启用，点「同步」拉取一次"
  }

  /// 错误横条：仅失败时出现，如实带原因（不清空已有数据）
  private func errorBanner(_ state: ExternalHeatStore.State) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Theme.accent)
      Text(state.statusText + (state.lastError.map { " · \($0)" } ?? ""))
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
      Spacer()
      Text(rows.isEmpty ? "尚无数据" : "已显示上次数据")
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textTertiary)
    }
    .padding(12)
    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radiusCard)
        .stroke(Theme.hairline, lineWidth: 1)
    )
  }

  /// 读本地快照（零 API 请求）：列表 + 连接状态
  private func reload() async {
    guard let queue = app.queue else { return }
    let store = ExternalHeatStore(queue: queue)
    loading = rows.isEmpty
    defer { loading = false }
    rows = configured ? ((try? await store.displayRows()) ?? []) : []
    state = try? await store.state()
    let connectionStore = WorkConnectionStore(queue: queue)
    let releases = (try? await connectionStore.activeReleases(sources: app.settings.enabledUpcomingSources)) ?? []
    let links = (try? await connectionStore.connections(for: releases, externalEnabled: configured)) ?? [:]
    var grouped: [String: [UpcomingRelease]] = [:]
    for release in releases {
      if let mediaID = links[release.id]?.mediaID { grouped[mediaID, default: []].append(release) }
    }
    upcomingWorks = grouped.mapValues { items in
      UpcomingWork(id: links[items[0].id]!.mediaID!, releaseDate: items.compactMap(\.releaseDate).min(), releases: items)
    }
    upcomingConnections = grouped.mapValues { WorkConnection.combined($0.compactMap { links[$0.id] }) }
  }

  /// 空态：图标 + 引导 + 直接开拉的按钮（不用去找右上角）
  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "chart.bar.xaxis")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(Theme.textTertiary)
      Text("还没有外部热度数据")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
      Text("来自你的 WhatsNew 服务 · 各榜采集时间独立展示")
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
      AccentButton(title: app.syncingExternalHeat ? "刷新中…" : "刷新热度") {
        Task { await app.refreshExternalHeat() }
      }
      .disabled(!configured || app.syncing || app.syncingExternalHeat || app.queue == nil)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - 榜单（海报网格 + 来源筛选）

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

  /// 来源 chips：单选一个来源榜（不同榜单名次不可比，不做"全部"混排）。
  /// 默认选中"组内最优名次"的来源（热度优先）
  private var sourceGroups: [(source: String, signals: [ExternalHeatStore.DisplayRow])] {
    Dictionary(grouping: rows, by: \.source)
      .map { (source: $0.key, signals: $0.value) }
      .sorted {
        let left = $0.signals.compactMap(\.rank).min() ?? 999
        let right = $1.signals.compactMap(\.rank).min() ?? 999
        return left == right ? $0.source < $1.source : left < right
      }
  }

  private var currentSource: String? {
    sourceGroups.contains { $0.source == selectedSource } ? selectedSource : sourceGroups.first?.source
  }

  private var sourceChips: some View {
    let groups = sourceGroups
    let current = currentSource

    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
      ForEach(groups, id: \.source) { group in
        let selected = group.source == current
        Button {
          selectedSource = group.source
        } label: {
          HStack(spacing: 5) {
            Text(ExternalSignalMeaning.label(for: group.source))
              .font(.system(size: 11, weight: selected ? .bold : .medium).monospacedDigit())
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("\(group.signals.count)")
              .font(.system(size: 10).monospacedDigit())
              .foregroundStyle(selected ? Theme.bg : Theme.textTertiary)
          }
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(selected ? Theme.accent : Theme.elevated)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(selected ? Theme.accent : Theme.hairline, lineWidth: 1)
          )
          .foregroundStyle(selected ? Theme.bg : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(group.source)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  /// 选中来源的网格（同剧集/电影页画廊；行内按名次排）
  private var gridSection: some View {
    let current = currentSource
    let signals = rows.filter { $0.source == current }
      .sorted { ($0.rank ?? 999) < ($1.rank ?? 999) }

    return ScrollViewReader { proxy in
      ScrollView {
        sourceChips
        Rectangle().fill(Theme.hairline).frame(height: 1)
        if let current, let explanation = ExternalSignalMeaning.explanation(for: current) {
          Text(explanation)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(signals, id: \.id) { row in
            signalCard(row)
              .id(row.id)
              .overlay {
                if app.externalFocus?.rowID == row.id {
                  RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.7), lineWidth: 1).padding(-6).allowsHitTesting(false)
                }
              }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .padding(.bottom, 26)
      }
      .task(id: "\(currentSource ?? "")|\(app.externalFocus?.token.uuidString ?? "")|\(rows.count)") {
        if let target = app.externalFocus, target.source == currentSource, rows.contains(where: { $0.id == target.rowID }) {
          await Task.yield()
          proxy.scrollTo(target.rowID, anchor: .center)
        }
      }
      .onChange(of: app.externalFocus) { _, target in
        if let target { selectedSource = target.source }
      }
    }
  }

  /// 海报卡：名次角标（左上琥珀）+ 名次变化徽标（右上，醒目）+ 标题 + 口径行
  private func signalCard(_ row: ExternalHeatStore.DisplayRow) -> some View {
    let title = row.video?.title.decodingHTMLEntities ?? row.mediaTitle
    return VStack(alignment: .leading, spacing: 6) {
      SignalPoster(url: posterURL(for: row), signals: [row])
        .overlay(alignment: .topLeading) {
          // 名次：海报左上角大角标
          Text(row.rank.map { "#\($0)" } ?? "—")
            .font(.system(size: 13, weight: .heavy).monospacedDigit())
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: Theme.radiusPoster, bottomTrailingRadius: Theme.radiusPoster))
        }


      VStack(alignment: .leading, spacing: 3) {
        if let work = upcomingWorks[row.mediaID] {
          Button { upcomingTarget = work } label: {
            Label("查看上线安排", systemImage: "calendar")
              .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
          }.buttonStyle(.plain).padding(.vertical, 3)
        }
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
        HStack(spacing: 6) {
          if row.video != nil {
            Circle().fill(Theme.accent).frame(width: 4, height: 4)
            Text("已关联")
          } else {
            Text("未关联")
          }
          if let platform = row.platform, !platform.isEmpty {
            Text(platform)
          }
          if let region = row.region, !region.isEmpty, region != "GLOBAL" {
            Text(region)
          }
          if row.rankingScope != "overall" {
            Text(row.rankingScope)
          }
          if let entryLabel = row.rankingEntryLabel, !entryLabel.isEmpty,
             row.rankingEntryKey != "work" {
            Text(entryLabel)
          }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.textTertiary)
        HStack(spacing: 6) {
          Text("采集 \(Self.shortTime(row.capturedAt))")
            .font(.system(size: 9.5).monospacedDigit())
          Spacer()
          // 名次变化：贴着采集时间放大一号，看得见
          if ExternalSignalPresentation.isHeat(row.source) && ExternalSignalPresentation.isFresh(row) {
            if let delta = ExternalSignalPresentation.rise(row) {
              Text("↑\(delta)")
                .font(.system(size: 11, weight: .heavy).monospacedDigit())
                .foregroundStyle(Theme.accent)
            } else if let delta = row.rankDelta, delta < 0 {
              Text("↓\(-delta)")
                .font(.system(size: 11, weight: .heavy).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            }
          }
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if let video = row.video {
        detailTarget = video
      } else if let work = upcomingWorks[row.mediaID] {
        upcomingTarget = work
      }
    }
    .help(row.video == nil ? "未关联本地条目（缺少可精确匹配的身份）" : "查看本地详情")
  }

  /// 同组榜的口径摘要：scope × window（entry 里的季信息在卡片标签行展示）
  private func scopesLabel(_ signals: [ExternalHeatStore.DisplayRow]) -> String {
    let scopes = Set(signals.map(\.rankingScope))
    let windows = Set(signals.compactMap(\.window).filter { !$0.isEmpty })
    var parts: [String] = Array(scopes)
    parts.append(contentsOf: windows)
    return parts.joined(separator: " · ")
  }

  /// 海报：匹配条目用本地库海报（含既有兜底链路）；未关联用 WhatsNew 海报代理
  /// （局域网自家服务，服务端有磁盘缓存；PosterLoader 懒加载 + NSCache，不逐行请求 API）
  private func posterURL(for row: ExternalHeatStore.DisplayRow) -> String? {
    if let video = row.video { return video.posterURL }
    guard var base = app.settings.whatsnewBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
          !base.isEmpty else { return nil }
    while base.hasSuffix("/") { base.removeLast() }
    return base + "/api/media/\(row.mediaID)/poster"
  }

    /// ISO 站方采集时间的短摘要（保留原文字段，显示截断；解析失败回退原文）
  static func shortTime(_ iso: String?) -> String {
    guard let iso, iso.count >= 10 else { return iso ?? "未知" }
    return String(iso.prefix(10)) // YYYY-MM-DD，自然日
  }
}
