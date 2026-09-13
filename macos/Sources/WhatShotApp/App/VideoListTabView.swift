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
    (filter.years != nil ? 1 : 0) + (filter.airingOnly ? 1 : 0) +
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
      page = 0
      rows = []
      await loadMore()
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

        SortTail(
          kinds: kind == .tvSeries ? [.premiere, .seedUpdated] : [.seedUpdated],
          selection: sort
        ) { sort = $0 }
      }
      .padding(.horizontal, 20)
    }
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
        selection: filter.airingOnly ? "播出中" : nil
      ) { next in
        switch next {
        case "播出中": filter.airingOnly = true
        case "已完结": filter.airingOnly = false // 已完结语义 = 不筛播出状态中的更新至；用空筛选代替二值开关
        default: filter.airingOnly = false
        }
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
      Text(filter.isEmpty ? "暂无数据" : "没有符合条件的条目")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
      Text(filter.isEmpty ? "点击右上角「同步」拉取数据" : "试试放宽筛选条件")
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
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
  }

  /// 任务 key：任何排序/筛选变化都整页重载
  private var reloadKey: String {
    "\(kind)-\(sort.rawValue)-\(filter.years ?? "-")-\(filter.airingOnly)-\(filter.classNames ?? "-")-\(filter.area ?? "-")"
  }

  func loadMore() async {
    guard !loading, let repo = app.repo else { return }
    loading = true
    defer { loading = false }
    let next = (try? await repo.listVideos(kind: kind, limit: pageSize, offset: page * pageSize, sort: sort, filter: filter)) ?? []
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