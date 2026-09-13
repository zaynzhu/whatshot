import SwiftUI
import WhatShotCore

/// 剧集 / 电影：区块页头 + 排序切换 + 筛选菜单行 + 画廊网格，底部懒加载
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

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(
        eyebrow: kind == .movie ? "MOVIES · BUTAI0" : "SERIES · BUTAI0",
        title: "最近更新",
        subtitle: sortSubtitle
      ) {
        Picker("", selection: $sort) {
          ForEach(availableSorts, id: \.self) { option in
            Text(option.rawValue).tag(option)
          }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
      }
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(.bottom, 12)

      filterBar
        .padding(.horizontal, 20)
        .padding(.bottom, 14)

      if rows.isEmpty && loading {
        Spacer()
        ProgressView("加载中…")
          .tint(Theme.accent)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
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
        }
        Spacer()
      } else {
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
    }
    .background(Theme.bg)
    .task(id: reloadKey) {
      page = 0
      rows = []
      await loadMore()
    }
  }

  /// 排序切换仅剧集页开放（电影无首播日语义，定案 Q6）
  private var availableSorts: [VideoRepository.ListSort] {
    kind == .tvSeries ? [.premiere, .seedUpdated] : [.seedUpdated]
  }

  /// 任务 key：任何排序/筛选变化都整页重载（筛选下分页 offset 无意义，数据量 <600 全量重拉也轻）
  private var reloadKey: String {
    "\(kind)-\(sort.rawValue)-\(filter.years ?? "-")-\(filter.airingOnly)-\(filter.classNames ?? "-")-\(filter.area ?? "-")"
  }

  // MARK: - 筛选菜单行（定案 Q2-round1：年代/状态/类型/地区，画质标签因覆盖不足不做）

  private var filterBar: some View {
    HStack(spacing: 10) {
      FilterMenu(
        label: "年代",
        options: FilterCatalog.yearBuckets,
        selection: filter.years,
        emptyText: "全部"
      ) { filter.years = $0 }

      if kind == .tvSeries {
        Picker("", selection: $filter.airingOnly) {
          Text("全部状态").tag(false)
          Text("播出中").tag(true)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
      }

      FilterMenu(
        label: "类型",
        options: FilterCatalog.classes,
        selection: filter.classNames,
        emptyText: "全部"
      ) { filter.classNames = $0 }

      FilterMenu(
        label: "地区",
        options: FilterCatalog.areas,
        selection: filter.area,
        emptyText: "全部"
      ) { filter.area = $0 }

      Spacer()

      if !filter.isEmpty {
        Button("清除筛选") {
          filter = VideoRepository.ListFilter()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accent)
        .buttonStyle(.plain)
      }
    }
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

/// 下拉筛选菜单：label + 当前值，nil = 全部
struct FilterMenu: View {
  let label: String
  let options: [String]
  let selection: String?
  let emptyText: String
  let onChange: (String?) -> Void

  var body: some View {
    Menu {
      Button(emptyText) { onChange(nil) }
      Divider()
      ForEach(options, id: \.self) { option in
        Button(option) { onChange(selection == option ? nil : option) }
      }
    } label: {
      HStack(spacing: 4) {
        Text(label)
          .foregroundStyle(Theme.textTertiary)
        Text(selection ?? emptyText)
          .foregroundStyle(selection == nil ? Theme.textSecondary : Theme.accent)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(Theme.textTertiary)
      }
      .font(.system(size: 11))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}