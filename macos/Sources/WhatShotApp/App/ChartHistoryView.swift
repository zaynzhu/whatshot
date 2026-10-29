import SwiftUI
import WhatShotCore

struct ChartHistoryView: View {
  let series: [ChartHistorySeries]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("最近 14 天 · 上榜轨迹", systemImage: "chart.xyaxis.line")
        .font(.system(size: 13, weight: .bold))
      Text("按北京时间日期 · 每格为当天末次名次")
        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
      ForEach(series) { row in
        VStack(alignment: .leading, spacing: 7) {
          Text(row.title).font(.system(size: 11, weight: .semibold))
          Text(row.context).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
            ForEach(row.days) { point in
              ChartHistoryCell(point: point)
            }
          }
        }
      }
      Text("— 表示未采样；未见表示站内末次完整快照未收录。外部按站方采集日记录，未返回不视为下榜；旧历史不补造，各榜名次不合成。")
        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }.foregroundStyle(Theme.textPrimary)
  }
}


private struct ChartHistoryCell: View {
  let point: ChartHistoryDay
  private var value: String { point.rank.map { "#\($0)" } ?? (point.sampled ? "未见" : "—") }
  private var explanation: String {
    point.rank.map { "末次名次 #\($0)" } ?? (point.sampled ? "当天末次完整快照中未见该作品" : "没有可判断的采样")
  }

  var body: some View {
    VStack(spacing: 4) {
      Text(String(point.day.suffix(5)))
        .font(.system(size: 8).monospacedDigit()).foregroundStyle(Theme.textTertiary)
      Text(value)
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(point.rank == nil ? Theme.textTertiary : Theme.accent)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 7)
    .background(point.rank == nil ? Theme.bg : Theme.accent.opacity(0.12),
      in: RoundedRectangle(cornerRadius: 4))
    .help(point.day + " · " + explanation)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(point.day + " · " + explanation)
  }
}
