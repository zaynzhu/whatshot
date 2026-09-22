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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(
        eyebrow: "EXTERNAL HEAT · WHATSNEW",
        title: "外部热度",
        subtitle: subtitle
      )
      .padding(.horizontal, 20)
      .padding(.top, 18)

      // 错误横条：只在最近一次拉取失败时显示（正常时不占版面）
      if let state, state.lastStatus != "ok", state.lastStatus != "never" {
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
        listSection
      }
    }
    .background(Theme.bg)
    .task { await reload() }
    // 同步完成后刷新（新快照可能带来新信号）
    .onChange(of: app.lastSummary) { _, _ in
      Task { await reload() }
    }
    .sheet(item: $detailTarget) { target in
      DetailSheet(video: target, repo: app.repo)
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
      if let captured = rows.compactMap(\.capturedAt).first {
        parts.append("站方采集 \(Self.shortTime(captured))")
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
    rows = (try? await store.displayRows()) ?? []
    state = try? await store.state()
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
      Text("来自你的 WhatsNew 服务 · 约 25 秒拉完")
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
      AccentButton(title: app.syncing ? "同步中…" : "立即同步") {
        Task { await app.syncNow() }
      }
      .disabled(app.syncing)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - 榜单

  /// 按 source 分组；组间按"组内最优名次"排（第一名所在的组在最前，热度优先）
  private var listSection: some View {
    let groups = Dictionary(grouping: rows, by: \.source)
      .map { (source: $0.key, signals: $0.value.sorted { ($0.rank ?? 999) < ($1.rank ?? 999) }) }
      .sorted {
        let l = $0.signals.first?.rank ?? 999
        let r = $1.signals.first?.rank ?? 999
        return l == r ? $0.source < $1.source : l < r
      }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(groups, id: \.source) { group in
          groupSection(group.source, signals: group.signals)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .padding(.bottom, 26)
    }
  }

  private func groupSection(_ source: String, signals: [ExternalHeatStore.DisplayRow]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // 榜头：来源 + 口径摘要——保留来源与口径，不伪装成统一总榜
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(source)
          .font(.system(size: 13, weight: .heavy).monospacedDigit())
          .foregroundStyle(Theme.accent)
        Text(scopesLabel(signals))
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.textTertiary)
        Spacer()
        Text("\(signals.count) 部")
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(Theme.textTertiary)
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(signals.enumerated()), id: \.element.id) { index, row in
          if index > 0 {
            Rectangle().fill(Theme.hairline).frame(height: 1)
              .padding(.leading, 14)
          }
          signalRow(row)
        }
      }
      .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.radiusCard)
          .stroke(Theme.hairline, lineWidth: 1)
      )
    }
  }

  /// 同组榜的口径摘要：scope × window（entry 里的季信息在行上展示）
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

  private func signalRow(_ row: ExternalHeatStore.DisplayRow) -> some View {
    let title = row.video?.title.decodingHTMLEntities ?? row.mediaTitle
    return HStack(spacing: 13) {
      // 名次：琥珀大号等宽——杂志层级的主角
      Text(row.rank.map { "\($0)" } ?? "—")
        .font(.system(size: 18, weight: .heavy).monospacedDigit())
        .foregroundStyle(Theme.accent)
        .frame(width: 30, alignment: .trailing)

      PosterImage(url: posterURL(for: row))
        .frame(width: 38)
        .fixedSize()

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          // 名次变化徽标：同榜内站方口径
          if let delta = row.rankDelta, delta > 0 {
            Text("↑\(delta)")
              .font(.system(size: 10, weight: .bold).monospacedDigit())
              .foregroundStyle(Theme.accent)
          } else if let delta = row.rankDelta, delta < 0 {
            Text("↓\(-delta)")
              .font(.system(size: 10, weight: .bold).monospacedDigit())
              .foregroundStyle(Theme.textTertiary)
          } else if row.previousRank == nil, row.rank != nil {
            Text("NEW")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(Theme.accent)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .overlay(
                RoundedRectangle(cornerRadius: 2)
                  .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
              )
          }
        }
        HStack(spacing: 8) {
          if row.video != nil {
            // 已关联：琥珀小点标记
            Circle()
              .fill(Theme.accent)
              .frame(width: 4, height: 4)
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
          // 季/版本：榜单席位自带，标签解析不出就不展示（不猜季）
          if let entryLabel = row.rankingEntryLabel, !entryLabel.isEmpty,
             row.rankingEntryKey != "work" {
            Text(entryLabel)
          }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textTertiary)
      }

      Spacer(minLength: 10)

      VStack(alignment: .trailing, spacing: 3) {
        // 站方采集时间：榜单新鲜度以此为准，不是本地请求时间
        Text("采集 \(Self.shortTime(row.capturedAt))")
          .font(.system(size: 10).monospacedDigit())
          .foregroundStyle(Theme.textTertiary)
        Text(ContentView.relativeTime(row.fetchedAt))
          .font(.system(size: 9.5).monospacedDigit())
          .foregroundStyle(Theme.textTertiary.opacity(0.75))
      }
    }
    .padding(.vertical, 11)
    .padding(.horizontal, 14)
    .contentShape(Rectangle())
    .onTapGesture {
      if let video = row.video {
        detailTarget = video
      }
    }
    .help(row.video == nil ? "未关联本地条目（缺少可精确匹配的身份）" : "查看本地详情")
  }

  /// ISO 站方采集时间的短摘要（保留原文字段，显示截断；解析失败回退原文）
  static func shortTime(_ iso: String?) -> String {
    guard let iso, iso.count >= 10 else { return iso ?? "未知" }
    return String(iso.prefix(10)) // YYYY-MM-DD，自然日
  }
}