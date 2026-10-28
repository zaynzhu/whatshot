import SwiftUI
import WhatShotCore

/// 排期独立于主站片库；仅从本地分页读取，不按系统时钟宣称影片已经可看。
struct UpcomingTabView: View {
  @Environment(AppModel.self) private var app
  @State private var source = "all"
  @State private var region = "CN"
  @State private var kind = "all"
  @State private var window: UpcomingWindow = .future
  @State private var rows: [UpcomingWork] = []
  @State private var states: [UpcomingSourceState] = []
  @State private var loading = false
  @State private var hasMore = false
  @State private var readError: String?
  @State private var queryGeneration = UUID()
  @State private var loadedFilter: String?
  @State private var showSources = false

  private var enabled: [UpcomingSource] { app.settings.enabledUpcomingSources }
  private var regionalSources: [UpcomingSource] { enabled.filter { $0.region == region } }
  private var selectedSources: [UpcomingSource] {
    regionalSources.filter { source == "all" || $0.rawValue == source }
  }
  private var filterKey: String { "\(region)|\(source)|\(kind)|\(window.rawValue)|\(enabled.map(\.rawValue).joined())" }
  private var queryKey: String { "\(filterKey)|\(app.upcomingRevision)|\(app.queue == nil)" }
  private var groups: [String] {
    var keys = Set(rows.map { $0.releaseDate ?? "待定档" }).sorted()
    if window == .recent { keys.reverse() }
    return keys
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(eyebrow: region == "CN" ? "平台排期 · 中国大陆" : "数字发行报道 · 美国", title: "即将上线",
                 subtitle: region == "CN" ? "按北京时间展示平台公布排期；未知时刻不补零点，排期不保证已可播放。"
                   : "美区数字付费报道，官宣状态未核实；不含预购、订阅与实体碟。保留美国日期，今日按美东日期划分。") {
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
        Picker("地区", selection: $region) {
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
      Picker("排期范围", selection: $window) {
        ForEach(UpcomingWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.labelsHidden().pickerStyle(.segmented)
        .frame(maxWidth: 360).padding(.horizontal, 20).padding(.bottom, 12)

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
                  Text(day == "待定档" ? day : day + (region == "US" ? " · 美国日期" : " · 北京时间"))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                  Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)], spacing: 18) {
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
    .onChange(of: region) { _, _ in source = "all"; kind = "all" }
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
      Text("国内：优酷、爱奇艺、腾讯。美国：When to Stream 数字付费报道，官宣状态未核实，不代表 Apple TV 等商店官方排期；未明确购买或租赁时不推测。")
    }
    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    .padding(20).frame(width: 320)
  }

  private var emptyTitle: String {
    if selectedSources.isEmpty { return "此地区的待播来源未开启" }
    if states.filter({ selectedSources.contains($0.source) }).allSatisfy({ $0.lastSuccessAt == nil }) { return "尚无待播快照" }
    return window == .undated ? "此筛选下没有待定档作品" : "此筛选下暂无已公布日期的作品"
  }
  private var emptyDetail: String {
    if selectedSources.isEmpty { return "点击「来源」开启此地区的数据源，再刷新排期。" }
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
      let page = try await store.works(sources: selectedSources, region: region, kind: kind == "all" ? nil : kind, window: window)
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
      let page = try await UpcomingStore(queue: queue).works(sources: selectedSources,
        region: region, kind: kind == "all" ? nil : kind, window: window, offset: rows.count)
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
  let row: UpcomingWork
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      PosterImage(url: row.posterURL).id(row.posterURL)
      Text(row.title).font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.textPrimary).lineLimit(2)
      Text(row.kind == "movie" ? "电影" : "剧集")
        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
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
              if release.source == .whenToStream {
                Text("美国 · 数字付费 · 报道排期").foregroundStyle(Theme.textTertiary)
                Text("官宣状态未核实").foregroundStyle(Theme.textTertiary)
              }
              if release.sourceReportsAvailable {
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
