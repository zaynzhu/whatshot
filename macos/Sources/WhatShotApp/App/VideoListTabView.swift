import SwiftUI
import WhatShotCore

/// 剧集 / 电影：区块页头 + 杂志目录式筛选条 + 画廊网格，底部懒加载
struct TVTabView: View {
  var body: some View {
    VideoGridTabView(kind: .tvSeries)
  }
}

struct MovieTabView: View {
  var body: some View {
    VideoGridTabView(kind: .movie)
  }
}

/// 筛选选项静态清单（对齐 butai0 字典 t1/t2/t3，docs/butai0-api.md）。
/// 不拉 getVideoTypeList：档位低频稳定，硬编码避免为 17+23+18 个选项多一类请求与缓存
enum FilterCatalog {
  /// 年代：与但ai0 列表筛选 se 参数同一套档位（本地按 years 数值映射区间）
  static let yearBuckets = ["近三年", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "20年代", "10年代", "00年代", "90年代", "80年代", "更早"]
  static let classes = ["剧情", "喜剧", "动作", "爱情", "科幻", "动画", "悬疑", "惊悚", "恐怖", "犯罪", "同性", "音乐", "歌舞", "传记", "历史", "战争", "西部", "奇幻", "冒险", "灾难", "武侠", "真人秀", "纪录片"]
  static let areas = ["大陆", "美国", "香港", "台湾", "日本", "韩国", "英国", "法国", "德国", "欧美", "西班牙", "印度", "泰国", "俄罗斯", "加拿大", "澳大利亚", "瑞典", "巴西"]
}

struct VideoGridTabView: View {
  let kind: ButaiKind
  @Environment(AppModel.self) private var app
  @State private var rows: [VideoRepository.VideoRow] = []
  @State private var loading = false
  @State private var page = 0
  /// 排序：剧集默认首播时间倒序（2026-09-13 定案 Q6），电影默认资源更新
  @State private var sort: VideoRepository.ListSort
  /// 筛选状态不跨启动持久化（定案 Q9-round1），每次进入默认全量
  @State private var filter = VideoRepository.ListFilter()
  /// 本地搜索（定案七）：searchText 是输入框即时值，searchQuery 防抖后参与查询；不跨启动持久化
  @State private var searchText = ""
  @State private var searchQuery = ""
  @State private var searchToken = UUID()
  @FocusState private var searchFocused: Bool
  private let pageSize = 60

  init(kind: ButaiKind) {
    self.kind = kind
    // 剧集页默认首播日倒序；电影页保持资源更新（定案 Q6）
    _sort = State(initialValue: kind == .tvSeries ? .premiere : .seedUpdated)
  }

  // 单元格顶对齐：集数行有无导致的卡片高度差不影响海报齐平
  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

  private var sortSubtitle: String {
    switch sort {
    case .premiere: return "按首播日期排序 · \(rows.count) 部"
    case .seedUpdated: return "按站内更新时间排序 · \(rows.count) 部"
    }
  }

  /// 已激活条件数（面包屑条状态行的琥珀强调）
  private var activeCount: Int {
    (filter.years != nil ? 1 : 0) + (filter.airing != .all ? 1 : 0) +
    (filter.classNames != nil ? 1 : 0) + (filter.area != nil ? 1 : 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageHeader(
        eyebrow: kind == .movie ? "MOVIES · BUTAI0" : "SERIES · BUTAI0",
        title: "最近更新",
        subtitle: sortSubtitle
      )
      .padding(.horizontal, 20)
      .padding(.top, 18)

      filterRail
        .padding(.top, 14)
        .padding(.bottom, 16)

      headerDivider

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        emptyState
        Spacer()
      } else {
        contentGrid
      }
    }
    .background(Theme.bg)
    .task(id: reloadKey) {
      await reloadFromScratch()
    }
    // 同步完成后重载当前列表（与 ChartTabView 同源信号）：集数、海报兜底结果无需切页可见
    .onChange(of: app.lastSummary) { _, _ in
      Task { await reloadFromScratch() }
    }
    // ⌘F 聚焦搜索：隐藏按钮只承担快捷键注册
    .background(
      Button { searchFocused = true } label: { EmptyView() }
        .keyboardShortcut("f", modifiers: .command)
    )
    .onChange(of: searchText) { _, next in
      let token = UUID()
      searchToken = token
      Task {
        try? await Task.sleep(nanoseconds: 250_000_000) // 防抖：停止输入才触发重查
        guard searchToken == token else { return }
        searchQuery = next
      }
    }
  }

  // MARK: - 杂志目录式筛选条（与 eyebrow 同源的文字层级，弃用系统控件灰）

  private var filterRail: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        ForEach(Array(filters.enumerated()), id: \.offset) { index, group in
          if index > 0 {
            railSeparator
          }
          FilterChipGroup(group)
        }

        Spacer(minLength: 14)

        searchField

        SortTail(
          kinds: kind == .tvSeries ? [.premiere, .seedUpdated] : [.seedUpdated],
          selection: sort
        ) { sort = $0 }
      }
      .padding(.horizontal, 20)
    }
  }

  /// 搜索框：与筛选条同语言（bg 底 + hairline 描边），⌘F 聚焦
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(searchFocused ? Theme.accent : Theme.textTertiary)
      TextField("搜索 片名/原名/别名", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textPrimary)
        .focused($searchFocused)
      if !searchText.isEmpty {
        Button {
          searchText = ""
          searchFocused = false
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radiusControl)
        .stroke(searchFocused ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1)
    )
    .frame(width: 190)
  }

  private var railSeparator: some View {
    Rectangle()
      .fill(Theme.hairline)
      .frame(width: 1, height: 13)
      .padding(.horizontal, 13)
  }

  /// 筛选条件分组（与 FilterCatalog 解耦的视图模型）
  private var filters: [ChipGroupModel] {
    var list: [ChipGroupModel] = []
    list.append(ChipGroupModel(
      eyebrow: "YEAR",
      label: "年代",
      options: FilterCatalog.yearBuckets,
      selection: filter.years
    ) { filter.years = $0 })
    if kind == .tvSeries {
      list.append(ChipGroupModel(
        eyebrow: "STATUS",
        label: "状态",
        options: ["播出中", "已完结"],
        selection: filter.airing == .all ? nil : filter.airing.rawValue
      ) { next in
        // 三态（2026-09-20）：播出中=更新至X集、已完结=全集；空（未知状态）两边都不算
        filter.airing = VideoRepository.AiringFilter(rawValue: next ?? "") ?? .all
      })
    }
    list.append(ChipGroupModel(
      eyebrow: "GENRE",
      label: "类型",
      options: FilterCatalog.classes,
      selection: filter.classNames
    ) { filter.classNames = $0 })
    list.append(ChipGroupModel(
      eyebrow: "REGION",
      label: "地区",
      options: FilterCatalog.areas,
      selection: filter.area
    ) { filter.area = $0 })
    return list
  }

  // MARK: - 页头分割线：细 hairline，筛选条与网格的分界

  private var headerDivider: some View {
    Rectangle()
      .fill(Theme.hairline)
      .frame(height: 1)
  }

  // MARK: - 空状态与网格

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: kind == .movie ? "film" : "tv")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(Theme.textTertiary)
      if !searchQuery.isEmpty {
        Text("没有找到「\(searchQuery)」相关作品")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.textSecondary)
        Text("只搜索已同步到本地的内容 · 试试更短的关键词")
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.textTertiary)
      } else {
        Text(filter.isEmpty ? "暂无数据" : "没有符合条件的条目")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.textSecondary)
        Text(filter.isEmpty ? "点击右上角「同步」拉取数据" : "试试放宽筛选条件")
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.textTertiary)
      }
      if !filter.isEmpty {
        Button("清除筛选条件") { filter = VideoRepository.ListFilter() }
          .font(.system(size: 11))
          .foregroundStyle(Theme.accent)
          .buttonStyle(.plain)
          .padding(.top, 2)
      }
    }
  }

  private var contentGrid: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 18) {
        ForEach(rows, id: \.id) { row in
          GalleryCard(video: row, showDefinition: true, showPremiere: sort == .premiere)
            .onTapGesture { detailTarget = row }
            .onAppear {
              if row.id == rows.last?.id {
                Task { await loadMore() }
              }
            }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 22)

      if loading && !rows.isEmpty {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("加载更多…")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.bottom, 16)
      }
    }
    .sheet(item: $detailTarget) { target in
      DetailSheet(video: target, repo: app.repo)
    }
  }

  /// 详情浮层目标（sheet 需要 Identifiable）
  @State private var detailTarget: VideoRepository.VideoRow?

  /// 任务 key：数据库就绪、排序/筛选/搜索变化都整页重载（repo nil→就位翻转让首屏等库就绪再加载）
  private var reloadKey: String {
    "\(app.repo != nil)-\(kind)-\(sort.rawValue)-\(filter.years ?? "-")-\(filter.airing.rawValue)-\(filter.classNames ?? "-")-\(filter.area ?? "-")-\(searchQuery)"
  }

  /// 重载代数：同步触发的重载与在途分页请求并发时，旧请求的结果按代数作废，
  /// 不混入清空后的 rows（.task(id:) 只取消自己启动的任务，管不到 onChange 的 Task）
  @State private var loadEpoch = 0

  /// 整页重载：回第一页。同步完成后浏览位置回到页首——手动同步本就期待看到新数据
  func reloadFromScratch() async {
    loadEpoch += 1
    page = 0
    rows = []
    await loadMore()
  }

  func loadMore() async {
    guard !loading, let repo = app.repo else { return }
    loading = true
    defer { loading = false }
    let epoch = loadEpoch
    let next = (try? await repo.listVideos(kind: kind, limit: pageSize, offset: page * pageSize,
                                           sort: sort, filter: filter,
                                           query: searchQuery.isEmpty ? nil : searchQuery)) ?? []
    guard epoch == loadEpoch else { return } // 期间发生过重载，旧页结果丢弃
    page += 1
    rows.append(contentsOf: next)
  }
}

// MARK: - 筛选条组件

/// 单个筛选组的视图模型
struct ChipGroupModel {
  let eyebrow: String
  let label: String
  let options: [String]
  let selection: String?
  let onChange: (String?) -> Void
}

/// 目录组：eyebrow + 自定义筛选浮层（深底 hairline 描边，弃用系统 Menu 的蓝灰原生观感）。
/// 选中项琥珀强调，与页面 eyebrow 层级同源——筛选条读作「目录」而不是「表单」
struct FilterChipGroup: View {
  let model: ChipGroupModel
  @State private var open = false

  init(_ model: ChipGroupModel) {
    self.model = model
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.eyebrow)
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .tracking(1.6)
        .foregroundStyle(model.selection == nil ? Theme.textTertiary : Theme.accent)
      HStack(spacing: 5) {
        Text(model.selection ?? model.label)
          .font(.system(size: 12.5, weight: model.selection == nil ? .medium : .semibold))
          .foregroundStyle(Theme.textPrimary)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .rotationEffect(.degrees(open ? 180 : 0))
          .foregroundStyle(Theme.textTertiary)
      }
    }
    .fixedSize()
    .contentShape(Rectangle())
    .onTapGesture { open.toggle() }
    .popover(isPresented: $open, arrowEdge: .top) {
      FilterOverlay(model: model) { value in
        model.onChange(value)
        open = false
      }
    }
  }
}

/// 自定义筛选浮层：与画廊同源的深色面板、选项竖排、选中琥珀，非系统菜单观感
/// popover 宽度随内容（fixedSize），长选项列表（类型 23 项）内部滚动
struct FilterOverlay: View {
  let model: ChipGroupModel
  let onSelect: (String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 顶部「全部」复位项（选中态 = 空时显示琥珀点）
      overlayRow(label: "全部", selected: model.selection == nil, accentWhenSelected: true) {
        onSelect(nil)
      }
      Rectangle()
        .fill(Theme.hairline)
        .frame(height: 1)
        .padding(.vertical, 2)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(model.options, id: \.self) { option in
            overlayRow(label: option, selected: model.selection == option, accentWhenSelected: true) {
              // 再次点击已选项 = 取消该筛选
              onSelect(model.selection == option ? nil : option)
            }
          }
        }
      }
      .frame(maxHeight: min(CGFloat(model.options.count) * 34, 340))
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(Theme.elevated)
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radiusCard)
        .stroke(Theme.hairline, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
  }

  private func overlayRow(label: String, selected: Bool, accentWhenSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 7) {
        // 选中标记：琥珀小圆点（比 checkmark 克制，与 eyebrow 单色纪律一致）
        Circle()
          .fill(selected && accentWhenSelected ? Theme.accent : Color.clear)
          .frame(width: 4, height: 4)
        Text(label)
          .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        Spacer(minLength: 20)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .fixedSize(horizontal: false, vertical: true)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// 排序尾部：与筛选 chip 同语言，选中项下加 2px 琥珀短线（TextTab 同款模式）
struct SortTail: View {
  let kinds: [VideoRepository.ListSort]
  let selection: VideoRepository.ListSort
  let onSelect: (VideoRepository.ListSort) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Theme.hairline)
        .frame(width: 1, height: 13)
        .padding(.horizontal, 15)
      // 两项间拉开：排序是“并列模式”而不是连续按钮组，间距给到 24
      ForEach(Array(kinds.enumerated()), id: \.offset) { index, option in
        if index > 0 {
          Spacer().frame(width: 24)
        }
        Button {
          onSelect(option)
        } label: {
          VStack(spacing: 3) {
            Text(option.rawValue)
              .font(.system(size: 11.5, weight: option == selection ? .semibold : .medium))
              .foregroundStyle(option == selection ? Theme.textPrimary : Theme.textTertiary)
            Rectangle()
              .fill(option == selection ? Theme.accent : Color.clear)
              .frame(width: 16, height: 2)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }
}