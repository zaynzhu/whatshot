import SwiftUI
import WhatShotCore

/// 排期独立于主站片库；仅从本地分页读取，不按系统时钟宣称影片已经可看。
struct UpcomingTabView: View {
  @Environment(AppModel.self) private var app
  @State private var source = "all"
  @State private var region = "all"
  @State private var kind = "all"
  @State private var mode: UpcomingBrowseMode = .all
  @State private var onlyUnread = false
  @State private var todayCount = 0
  @State private var weekCount = 0
  @State private var unreadCount = 0
  @Environment(\.scenePhase) private var scenePhase
  @State private var calendarRevision = 0
  @State private var changes: [UpcomingWantChange] = []
  @State private var inactiveIDs = Set<String>()
  @State private var window: UpcomingWindow = .future
  @State private var rows: [UpcomingWork] = []
  @State private var states: [UpcomingSourceState] = []
  @State private var loading = false
  @State private var hasMore = false
  @State private var readError: String?
  @State private var queryGeneration = UUID()
  @State private var loadedFilter: String?
  @State private var showSources = false
  @State private var connections: [String: WorkConnection] = [:]
  @State private var detailTarget: UpcomingWork?

  private var enabled: [UpcomingSource] { app.settings.enabledUpcomingSources }
  private var regionalSources: [UpcomingSource] { enabled.filter { region == "all" || $0.region == region } }
  private var selectedRegion: String? { region == "all" ? nil : region }
  private var selectedSources: [UpcomingSource] {
    regionalSources.filter { source == "all" || $0.rawValue == source }
  }
  private var filterKey: String { "\(mode.rawValue)|\(onlyUnread)|\(region)|\(source)|\(kind)|\(window.rawValue)|\(enabled.map(\.rawValue).joined())" }
  private var queryKey: String { "\(calendarRevision)|\(filterKey)|\(app.wishlistRevision)|\(app.upcomingRevision)|\(app.externalRevision)|\(app.externalEnabled)|\(app.queue == nil)" }
  private var eyebrow: String {
    switch region {
    case "CN": "平台排期 · 中国大陆"
    case "US": "数字发行报道 · 美国"
    default: "平台排期与数字发行 · 全部地区"
    }
  }
  private var subtitle: String {
    switch region {
    case "CN": "按北京时间展示平台公布排期；未知时刻不补零点，排期不保证已可播放。"
    case "US": "美区数字付费报道，官宣状态未核实；不含预购、订阅与实体碟。保留美国日期，今日按美东日期划分。"
    default: "国内排期与美区数字发行合并展示，保留各地区日期。国内按北京时间、美区按美东日期筛选；报道标明官宣未核实。"
    }
  }
  private var dateLabel: String {
    switch region {
    case "CN": "北京时间"
    case "US": "美国日期"
    default: "各地区日期"
    }
  }
  private func groupDay(_ work: UpcomingWork) -> String {
    if mode == .changes {
      let ids = Set(work.releases.map(\.id))
      return changes.first { ids.contains($0.releaseID) }.map { UpcomingDate.day($0.observedAt) } ?? "较早变动"
    }
    return work.releaseDate ?? "待定档"
  }

  private var groups: [String] {
    var keys = Set(rows.map(groupDay)).sorted()
    if mode == .changes || (mode == .all && window == .recent) { keys.reverse() }
    return keys
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(eyebrow: eyebrow, title: "即将上线", subtitle: subtitle) {
        HStack(spacing: 8) {
          OutlineButton(title: "来源", icon: "slider.horizontal.3") { showSources.toggle() }
            .popover(isPresented: $showSources) { sourceSettings }
          if app.syncingUpcoming {
            OutlineButton(title: "停止", icon: "xmark") { app.stopUpcoming() }
          } else {
            OutlineButton(title: "补全片名", icon: "character.bubble") { Task { await app.localizeUpcomingTitles() } }
              .disabled(!enabled.contains(.whenToStream) || (app.settings.tmdbApiKey ?? "").isEmpty || app.queue == nil)
              .help("核验下一批美区电影的中文片名，最多 10 部；需在设置中配置 TMDB。首次先刷新排期。")
            OutlineButton(title: "刷新排期", icon: "arrow.clockwise") { Task { await app.syncUpcoming() } }
              .disabled(enabled.isEmpty || app.queue == nil)
          }
        }
      }
      .padding(20)

      HStack(spacing: 12) {
        Picker("地区", selection: $region) {
          Text("全部地区").tag("all")
          Text("中国大陆").tag("CN")
          Text("美国 · 发行报道").tag("US")
        }.labelsHidden().frame(width: 160)
        Picker("来源", selection: $source) {
          Text("全部来源").tag("all")
          ForEach(regionalSources) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().frame(width: 120)
        Picker("类型", selection: $kind) {
          Text("全部类型").tag("all")
          Text("电影").tag("movie")
          Text("剧集").tag("series")
        }.labelsHidden().frame(width: 100)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ActivityShortcut(title: "今日想看排期", count: todayCount, icon: "calendar", selected: mode == .today) { mode = .today }
          ActivityShortcut(title: "本周想看", count: weekCount, icon: "calendar.badge.clock", selected: mode == .week) { mode = .week }
          ActivityShortcut(title: "未读变动", count: unreadCount, icon: "bell.badge", selected: mode == .changes && onlyUnread) {
            onlyUnread = true
            mode = .changes
          }
        }
      }.padding(.horizontal, 20).padding(.bottom, 12)
      Picker("浏览范围", selection: $mode) {
        ForEach(UpcomingBrowseMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.labelsHidden().pickerStyle(.segmented)
        .frame(maxWidth: 540).padding(.horizontal, 20).padding(.bottom, 12)

      if mode == .all {
        Picker("排期范围", selection: $window) {
          ForEach(UpcomingWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.segmented)
          .frame(maxWidth: 360).padding(.horizontal, 20).padding(.bottom, 12)
      } else {
        Text(mode == .today ? "关注作品的今日排期 · 各地区自然日 · 排期不代表已可播放" : mode == .week ? "关注作品的本周排期 · 各地区周一至周日 · 到期不代表已可播放"
          : (mode == .changes ? "最近 90 天关注作品的排期变动 · 点击海报查看完整记录"
            : "已收藏的平台排期 · 包含待定档及移出片单作品 · 来源关闭时隐藏"))
          .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
          .padding(.horizontal, 20).padding(.bottom, 12)
      }
      if mode == .changes {
        Toggle("只看未读变动", isOn: $onlyUnread).toggleStyle(.checkbox)
          .font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 10)
      }
      if app.syncingUpcoming {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(app.upcomingPhase ?? "刷新中…")
        }
        .font(.system(size: 11)).foregroundStyle(Theme.accent)
        .padding(.horizontal, 20).padding(.bottom, 10)
      }
      if let message = readError ?? app.upcomingError {
        Text(message).font(.system(size: 11)).foregroundStyle(Theme.accent)
          .padding(.horizontal, 20).padding(.bottom, 10)
      }
      sourceStatus
      Divider().overlay(Theme.hairline)

      if rows.isEmpty {
        VStack(spacing: 12) {
          if loading { ProgressView() }
          Image(systemName: "calendar").font(.system(size: 32, weight: .light))
          Text(emptyTitle).font(.system(size: 16, weight: .semibold))
          Text(emptyDetail).font(.system(size: 12)).multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(groups, id: \.self) { day in
              VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                  Circle().fill(Theme.accent).frame(width: 6, height: 6)
                  Text(day == "待定档" ? day : day + " · " + (mode == .changes ? "本地发现日期" : dateLabel))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                  Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)], spacing: 18) {
                  ForEach(rows.filter { groupDay($0) == day }) { row in
                    let connection = WorkConnection.combined(row.releases.compactMap { connections[$0.id] })
                    UpcomingCard(row: row, connection: connection, inactiveIDs: inactiveIDs,
                      change: changes.first { change in row.releases.contains { $0.id == change.releaseID } }) { detailTarget = row }
                  }
                }
              }
            }
            if hasMore {
              HStack {
                Spacer()
                OutlineButton(title: loading ? "读取中…" : "加载更多", icon: "chevron.down") {
                  Task { await loadMore() }
                }.disabled(loading)
                Spacer()
              }
            }
          }
          .padding(20)
        }
      }
    }
    .background(Theme.bg)
    .sheet(item: $detailTarget, onDismiss: { Task { await reload() } }) { row in
      UpcomingDetailSheet(row: row, connection: WorkConnection.combined(row.releases.compactMap { connections[$0.id] }))
    }
    .task(id: queryKey) { await reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { calendarRevision += 1 }
    }
    .onChange(of: region) { _, _ in source = "all"; kind = "all" }
    .onChange(of: enabled) { _, value in
      if source != "all", !value.contains(where: { $0.rawValue == source }) { source = "all" }
    }
  }

  private var sourceStatus: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
      Text("\(selectedSources.count) 个来源 · 已加载 \(rows.count) 部作品")
      if states.contains(where: { selectedSources.contains($0.source) && $0.error != nil }) {
        Text("部分来源使用旧快照").foregroundStyle(Theme.accent)
      }
      Spacer()
      Text("点击海报查看排期与榜单").foregroundStyle(Theme.textTertiary)
    }
    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
    .padding(.horizontal, 20).padding(.bottom, 12)
  }

  private var sourceSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("待播来源").font(.headline)
      ForEach(UpcomingSource.allCases) { source in
        Toggle(source.title, isOn: Binding(get: { enabled.contains(source) }, set: { value in
          var settings = app.settings
          settings.upcomingSources = UpcomingSource.allCases.filter { $0 == source ? value : enabled.contains($0) }
          Task { await app.updateSettings(settings) }
        }))
      }
      ForEach(states.filter { enabled.contains($0.source) }, id: \.source) { state in
        VStack(alignment: .leading, spacing: 3) {
          Text("\(state.source.title) · \(state.count) 条 · " + (state.lastSuccessAt.map { ContentView.relativeTime($0) } ?? "尚未同步"))
          if let error = state.error { Text(error).foregroundStyle(Theme.accent) }
        }.font(.system(size: 10))
      }
      Text("自动刷新沿用设置中的同步间隔。关闭来源后隐藏其缓存并停止当前刷新；开启后可手动刷新。")
      Divider()
      Text("国内：优酷、爱奇艺、腾讯。美国：When to Stream 数字付费报道，官宣状态未核实，不代表 Apple TV 等商店官方排期；未明确购买或租赁时不推测。")
    }
    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    .padding(20).frame(width: 320)
  }

  private var emptyTitle: String {
    if selectedSources.isEmpty { return "此地区的待播来源未开启" }
    if mode == .wanted { return "还没有符合条件的想看作品" }
    if mode == .today { return "今天暂无已公布排期的想看作品" }
    if mode == .changes && onlyUnread { return "没有未读排期变动" }
    if mode == .week { return "本周暂无已公布排期的想看作品" }
    if mode == .changes { return "关注后尚未发现排期变动" }
    if states.filter({ selectedSources.contains($0.source) }).allSatisfy({ $0.lastSuccessAt == nil }) { return "尚无待播快照" }
    return window == .undated ? "此筛选下没有待定档作品" : "此筛选下暂无已公布日期的作品"
  }
  private var emptyDetail: String {
    if selectedSources.isEmpty { return "点击「来源」开启此地区的数据源，再刷新排期。" }
    if mode != .all { return "可在全部片单中点「想看」收藏；变动只在关注后成功刷新时记录。来源与地区筛选仍生效。" }
    if window == .future { return "可以刷新排期，或切换「待定档」查看尚未公布日期的片单。" }
    if window == .recent { return "这里只展示过去 14 天的排期，不代表已经可以播放。" }
    return "公开片单随平台公告更新，未公布的日期与时刻不会推测补齐。"
  }

  @MainActor private func reload() async {
    let generation = UUID()
    queryGeneration = generation
    loading = true
    if loadedFilter != filterKey { rows = []; loadedFilter = filterKey }
    hasMore = false
    guard let queue = app.queue else { loading = false; return }
    do {
      let store = UpcomingStore(queue: queue)
      let states = try await store.states()
      try await app.reloadWishlist()
      let page = try await loadPage(offset: 0)
      let wishlist = UpcomingWishlistStore(queue: queue)
      let today = try await wishlist.count(mode: .today, sources: selectedSources, region: selectedRegion, kind: kind == "all" ? nil : kind)
      let week = try await wishlist.count(mode: .week, sources: selectedSources, region: selectedRegion, kind: kind == "all" ? nil : kind)
      let unread = try await wishlist.count(mode: .changes, sources: selectedSources, region: selectedRegion, kind: kind == "all" ? nil : kind, unreadOnly: true)
      let changes = try await wishlist.changes(for: page.flatMap(\.releases).map(\.id))
      let inactive = try await wishlist.inactiveIDs(for: page.flatMap(\.releases).map(\.id))
      let linked = try await WorkConnectionStore(queue: queue).connections(for: page.flatMap(\.releases), externalEnabled: app.externalEnabled)
      guard !Task.isCancelled, generation == queryGeneration else { return }
      todayCount = today
      weekCount = week
      unreadCount = unread
      connections = linked
      self.changes = changes
      inactiveIDs = inactive
      self.states = states
      rows = page
      hasMore = page.count == 60
      readError = nil
    } catch {
      guard !Task.isCancelled, generation == queryGeneration else { return }
      readError = "本地排期读取失败，请重新打开此页"
    }
    if generation == queryGeneration { loading = false }
  }

  @MainActor private func loadPage(offset: Int) async throws -> [UpcomingWork] {
    guard let queue = app.queue else { return [] }
    if mode == .all {
      return try await UpcomingStore(queue: queue).works(sources: selectedSources,
        region: selectedRegion, kind: kind == "all" ? nil : kind, window: window, externalEnabled: app.externalEnabled, offset: offset)
    }
    return try await UpcomingWishlistStore(queue: queue).works(mode: mode, sources: selectedSources,
      region: selectedRegion, kind: kind == "all" ? nil : kind, unreadOnly: onlyUnread, offset: offset)
  }

  @MainActor private func loadMore() async {
    guard !loading, let queue = app.queue else { return }
    let generation = queryGeneration
    loading = true
    do {
      let page = try await loadPage(offset: rows.count)
      let wishlist = UpcomingWishlistStore(queue: queue)
      let changes = try await wishlist.changes(for: page.flatMap(\.releases).map(\.id))
      let inactive = try await wishlist.inactiveIDs(for: page.flatMap(\.releases).map(\.id))
      let linked = try await WorkConnectionStore(queue: queue).connections(for: page.flatMap(\.releases), externalEnabled: app.externalEnabled)
      guard !Task.isCancelled, generation == queryGeneration else { return }
      connections.merge(linked) { _, new in new }
      self.changes += changes
      inactiveIDs.formUnion(inactive)
      rows += page
      hasMore = page.count == 60
      readError = nil
    } catch {
      if generation == queryGeneration { readError = "加载更多失败，已有片单保留" }
    }
    if generation == queryGeneration { loading = false }
  }
}

private struct UpcomingCard: View {
  let row: UpcomingWork
  let connection: WorkConnection
  let inactiveIDs: Set<String>
  let change: UpcomingWantChange?
  let open: () -> Void
  private var localCharts: [LocalChartSignal] { connection.videoID.flatMap { app.localChartSignals[$0] } ?? [] }
  @Environment(AppModel.self) private var app
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button(action: open) {
        SignalPoster(url: row.posterURL, signals: app.signals(for: connection), localCharts: localCharts).id(row.posterURL)
      }.buttonStyle(.plain).help("查看作品排期与外部榜单")
        .accessibilityLabel("查看\(connection.chineseTitle ?? row.title)详情")
      Button(action: open) {
        Text(connection.chineseTitle ?? row.title).font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(Theme.textPrimary).lineLimit(2)
      }.buttonStyle(.plain)
      if let title = connection.chineseTitle, title != row.title {
        Text(row.title).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(2)
      }
      UpcomingWantButton(work: row)
      if let change {
        Text((change.isRead ? "" : "未读 · ") + change.before.source.title + " · " + change.label)
          .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
        Text(change.summary).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(3)
      }
      WorkChartBadge(local: localCharts, external: app.signals(for: connection), prefix:
        row.releases.contains(where: { app.wantedReleaseIDs.contains($0.id) }) && WorkHeatTier.resolve(local: localCharts, external: app.signals(for: connection)) != .none ? "想看 · " : "")
      Text(row.kind == "movie" ? "电影" : "剧集")
        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
      if row.releases.first?.region == "CN" {
        Text("中国大陆 · 北京时间")
          .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
      }
      ForEach(row.releases) { release in
        if let url = URL(string: release.sourceURL) {
          Link(destination: url) {
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(release.source.title).fontWeight(.semibold)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.system(size: 8))
              }.foregroundStyle(Theme.textSecondary)
              Text(release.releaseDate.map { $0 + " · " + release.timeText } ?? "待定档")
                .monospacedDigit()
                .foregroundStyle(release.releaseTime == nil ? Theme.textSecondary : Theme.accent)
              if inactiveIDs.contains(release.id) {
                Text("已移出片单 · 保留上次排期").foregroundStyle(Theme.accent)
                Text("是否上线未确认").foregroundStyle(Theme.textTertiary)
              }
              if release.source == .whenToStream {
                Text("美国 · 数字付费 · 报道排期").foregroundStyle(Theme.textTertiary)
                Text("官宣状态未核实").foregroundStyle(Theme.textTertiary)
              }
              if release.sourceReportsAvailable && !inactiveIDs.contains(release.id) {
                Text("来源标记已上线").foregroundStyle(Theme.accent)
              }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("\(release.rawSchedule)\n核实于 \(ContentView.relativeTime(release.observedAt))\n" +
            (release.sourceURL == "https://www.iqiyi.com/newOnlinePCW" ? "详情未公布，打开平台片单" : "打开平台原站"))
          if release.id != row.releases.last?.id { Divider().overlay(Theme.hairline) }
        }
      }
    }
    .font(.system(size: 10.5))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
