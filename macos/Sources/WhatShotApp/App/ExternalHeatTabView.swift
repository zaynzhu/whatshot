import SwiftUI
import WhatShotCore

/// 外部热度（2026-09-22 WhatsNew 可选接入）：用户自有 WhatsNew 服务的来源榜单展示。
/// 保留来源、榜、窗口与季版本（entry_key 独立席位），不跨源混算排名；
/// 匹配本地条目可进详情，未关联条目保留在榜单里如实显示。
/// 数据来自同步时写入的本地快照——本页零网络请求，离线也不影响追剧
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

      statusSection
        .padding(.horizontal, 20)
        .padding(.top, 14)

      Rectangle()
        .fill(Theme.hairline)
        .frame(height: 1)
        .padding(.top, 14)

      if loading && rows.isEmpty {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if configured && rows.isEmpty {
        Spacer()
        emptyState
        Spacer()
      } else {
        listSection
      }
    }
    .background(Theme.bg)
    .task { await reload() }
    // 同步完成后刷新（新快照可能带来新信号），但不重复查状态
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
    if let mediaCount = state?.lastMediaCount, state?.lastStatus == "ok" {
      return "最近一次覆盖 \(mediaCount) 部作品 · 榜单随同步更新"
    }
    return "榜单随同步更新，数据来自你的 WhatsNew 服务"
  }

  /// 连接状态区：未配置引导、失败如实、正常带站方采集时间
  private var statusSection: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 5, height: 5)
      Text(statusText)
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
      Spacer()
    }
    .padding(14)
    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radiusCard)
        .stroke(Theme.hairline, lineWidth: 1)
    )
  }

  private var statusColor: Color {
    guard configured else { return Theme.textTertiary }
    switch state?.lastStatus {
    case "ok": return Theme.accent
    case "never": return Theme.textTertiary
    default: return .red.opacity(0.9)
    }
  }

  private var statusText: String {
    guard configured else { return "未启用：在「设置」填入 WhatsNew 服务地址并打开开关" }
    guard let state else { return "已启用，等待下一轮同步拉取" }
    var parts: [String] = [state.statusText]
    if state.lastStatus == "ok", let successAt = state.lastSuccessAt {
      parts.append("本地发现 \(ContentView.relativeTime(successAt))")
    }
    if let error = state.lastError, state.lastStatus != "ok" {
      parts.append(error)
    }
    // 成功时展示站方最新采集时间（有信号的最早 capturedAt）——
    // 本地取到响应的时间不冒充榜单更新时间
    if state.lastStatus == "ok", let captured = rows.compactMap(\.capturedAt).first {
      parts.append("站方采集 \(captured)")
    }
    return parts.joined(separator: " · ")
  }

  /// 读本地快照（零网络请求）：列表 + 连接状态
  private func reload() async {
    guard let queue = app.queue else { return }
    let store = ExternalHeatStore(queue: queue)
    loading = rows.isEmpty
    defer { loading = false }
    rows = (try? await store.displayRows()) ?? []
    state = try? await store.state()
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "chart.bar.xaxis")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(Theme.textTertiary)
      Text("还没有外部热度数据")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
      Text("点右上角「同步」拉取一次，或等下轮自动同步")
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
    }
  }

  // MARK: - 榜单

  /// 按 source 分组的榜单（displayRows 已按 source/scope/window/rank 排）
  private var listSection: some View {
    let groups = Dictionary(grouping: rows, by: \.source)
      .map { (source: $0.key, signals: $0.value) }
      .sorted { $0.source < $1.source }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(groups, id: \.source) { group in
          groupSection(group.source, signals: group.signals)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .padding(.bottom, 22)
    }
  }

  private func groupSection(_ source: String, signals: [ExternalHeatStore.DisplayRow]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      // 榜头：来源 + 范围 + 窗口——保留来源与口径，不伪装成统一总榜
      HStack(spacing: 8) {
        Text(source)
          .font(.system(size: 12, weight: .bold).monospacedDigit())
          .foregroundStyle(Theme.accent)
        Text(scopesLabel(signals))
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.textTertiary)
        Spacer()
      }
      .padding(.top, 8)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(signals.enumerated()), id: \.element.id) { index, row in
          if index > 0 {
            Rectangle().fill(Theme.hairline).frame(height: 1)
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

  private func signalRow(_ row: ExternalHeatStore.DisplayRow) -> some View {
    let title = row.video?.title.decodingHTMLEntities ?? row.mediaTitle
    return HStack(spacing: 12) {
      // 名次：琥珀等宽，未排名留空占位
      Text(row.rank.map { "\($0)" } ?? "—")
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(Theme.accent)
        .frame(width: 24, alignment: .trailing)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          // 名次变化徽标：↑n/↓n/new，同榜内站方口径
          if let delta = row.rankDelta, delta > 0 {
            Text("↑\(delta)")
              .font(.system(size: 9.5, weight: .bold).monospacedDigit())
              .foregroundStyle(Theme.accent)
          } else if let delta = row.rankDelta, delta < 0 {
            Text("↓\(-delta)")
              .font(.system(size: 9.5, weight: .bold).monospacedDigit())
              .foregroundStyle(Theme.textTertiary)
          } else if row.previousRank == nil, row.rank != nil {
            Text("NEW")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(Theme.accent)
          }
        }
        HStack(spacing: 8) {
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
          if row.video != nil {
            Text("已关联")
          } else {
            Text("未关联")
          }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textTertiary)
      }

      Spacer(minLength: 10)

      VStack(alignment: .trailing, spacing: 3) {
        // 站方采集时间：榜单新鲜度以此为准，不是本地请求时间
        if let captured = row.capturedAt {
          Text("采集 \(Self.shortTime(captured))")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
        }
        Text("发现于 \(ContentView.relativeTime(row.fetchedAt))")
          .font(.system(size: 9.5).monospacedDigit())
          .foregroundStyle(Theme.textTertiary.opacity(0.8))
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .contentShape(Rectangle())
    .onTapGesture {
      if let video = row.video {
        detailTarget = video
      }
    }
  }

  /// ISO 站方采集时间的短摘要（保留原文字段，显示截断；解析失败回退原文）
  static func shortTime(_ iso: String?) -> String {
    guard let iso, iso.count >= 10 else { return iso ?? "未知" }
    return String(iso.prefix(10)) // YYYY-MM-DD，自然日
  }
}
