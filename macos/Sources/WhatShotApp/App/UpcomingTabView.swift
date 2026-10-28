import SwiftUI
import WhatShotCore

/// 排期独立于主站片库；仅从本地分页读取，不按系统时钟宣称影片已经可看。
struct UpcomingTabView: View {
  @Environment(AppModel.self) private var app
  @State private var source = "all"
  @State private var kind = "all"
  @State private var window: UpcomingWindow = .future
  @State private var rows: [UpcomingRelease] = []
  @State private var states: [UpcomingSourceState] = []
  @State private var loading = false
  @State private var hasMore = false
  @State private var readError: String?
  @State private var queryGeneration = UUID()
  @State private var loadedFilter: String?
  @State private var showSources = false

  private var enabled: [UpcomingSource] { app.settings.enabledUpcomingSources }
  private var selectedSources: [UpcomingSource] {
    enabled.filter { source == "all" || $0.rawValue == source }
  }
  private var filterKey: String { "\(source)|\(kind)|\(window.rawValue)|\(enabled.map(\.rawValue).joined())" }
  private var queryKey: String { "\(filterKey)|\(app.upcomingRevision)|\(app.queue == nil)" }
  private var groups: [String] {
    var keys = Set(rows.map { $0.releaseDate ?? "待定档" }).sorted()
    if window == .recent { keys.reverse() }
    return keys
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(eyebrow: "平台排期 · 中国大陆", title: "即将上线",
                 subtitle: "按北京时间展示平台公布排期；未知时刻不补零点，排期不保证已可播放。") {
        HStack(spacing: 8) {
          OutlineButton(title: "来源", icon: "slider.horizontal.3") { showSources.toggle() }
            .popover(isPresented: $showSources) { sourceSettings }
          if app.syncingUpcoming {
            OutlineButton(title: "停止", icon: "xmark") { app.stopUpcoming() }
          } else {
            OutlineButton(title: "刷新排期", icon: "arrow.clockwise") { Task { await app.syncUpcoming() } }
              .disabled(enabled.isEmpty || app.queue == nil)
          }
        }
      }
      .padding(20)

      HStack(spacing: 12) {
        Picker("来源", selection: $source) {
          Text("全部平台").tag("all")
          ForEach(enabled) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().frame(width: 120)
        Picker("类型", selection: $kind) {
          Text("全部类型").tag("all")
          Text("电影").tag("movie")
          Text("剧集").tag("series")
        }.labelsHidden().frame(width: 100)
        Picker("排期范围", selection: $window) {
          ForEach(UpcomingWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.segmented)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)

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
                  Text(day == "待定档" ? day : day + " · 北京时间")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                  Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)], spacing: 18) {
                  ForEach(rows.filter { ($0.releaseDate ?? "待定档") == day }) { row in
                    UpcomingCard(row: row)
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
    .task(id: queryKey) { await reload() }
    .onChange(of: enabled) { _, value in
      if source != "all", !value.contains(where: { $0.rawValue == source }) { source = "all" }
    }
  }

  private var sourceStatus: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(selectedSources) { source in
        let state = states.first { $0.source == source }
        HStack(alignment: .top, spacing: 6) {
          Text(source.title).foregroundStyle(Theme.textSecondary)
          if let state {
            Text(state.lastSuccessAt.map { "\(state.count) 部 · 更新于 \(ContentView.relativeTime($0))" } ?? "尚未成功读取")
            if let error = state.error {
              Text("· \(error)" + (state.lastSuccessAt == nil ? "" : " · 显示旧快照"))
                .foregroundStyle(Theme.accent)
            }
          } else { Text("尚未同步") }
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
      }
    }.padding(.horizontal, 20).padding(.bottom, 12)
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
      Text("自动刷新沿用设置中的同步间隔。关闭来源后隐藏其缓存并停止当前刷新；开启后可手动刷新。")
      Divider()
      Text("芒果与海外数字发行仍在验证入口，尚未接入。海外将区分地区、购买、租赁与订阅。")
    }
    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    .padding(20).frame(width: 320)
  }

  private var emptyTitle: String {
    if enabled.isEmpty { return "待播来源已全部关闭" }
    if states.filter({ selectedSources.contains($0.source) }).allSatisfy({ $0.lastSuccessAt == nil }) { return "尚无待播快照" }
    return window == .undated ? "此筛选下没有待定档作品" : "此筛选下暂无已公布日期的作品"
  }
  private var emptyDetail: String {
    if enabled.isEmpty { return "点击「来源」开启平台" }
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
      let page = try await store.releases(sources: selectedSources, kind: kind == "all" ? nil : kind, window: window)
      guard !Task.isCancelled, generation == queryGeneration else { return }
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

  @MainActor private func loadMore() async {
    guard !loading, let queue = app.queue else { return }
    let generation = queryGeneration
    loading = true
    do {
      let page = try await UpcomingStore(queue: queue).releases(sources: selectedSources,
        kind: kind == "all" ? nil : kind, window: window, offset: rows.count)
      guard !Task.isCancelled, generation == queryGeneration else { return }
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
  let row: UpcomingRelease
  var body: some View {
    if let url = URL(string: row.sourceURL) {
      Link(destination: url) {
        VStack(alignment: .leading, spacing: 6) {
          PosterImage(url: row.posterURL).id(row.posterURL)
          Text(row.title).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textPrimary).lineLimit(2)
          Text(row.timeText).font(.system(size: 15, weight: .bold).monospacedDigit())
            .foregroundStyle(row.releaseTime == nil ? Theme.textSecondary : Theme.accent)
          Text("\(row.source.title) · \(row.kind == "movie" ? "电影" : "剧集")")
            .foregroundStyle(Theme.textSecondary)
          Text(row.rawSchedule).foregroundStyle(Theme.textTertiary).lineLimit(2)
          if row.sourceReportsAvailable {
            Text("来源标记已上线").foregroundStyle(Theme.accent)
          }
          Text("核实于 \(ContentView.relativeTime(row.observedAt)) ↗")
            .foregroundStyle(Theme.textTertiary)
          if row.sourceURL == "https://www.iqiyi.com/newOnlinePCW" {
            Text("详情未公布 · 查看平台片单").foregroundStyle(Theme.textTertiary)
          }
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("\(row.title) · \(row.rawSchedule)\n打开\(row.source.title)原站；地区：中国大陆")
    }
  }
}
