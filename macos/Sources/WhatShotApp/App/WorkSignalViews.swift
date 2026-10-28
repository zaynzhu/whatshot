import SwiftUI
import WhatShotCore

/// 光边携带语义：当前热度用琥珀，其他榜单／旧记录用柔和细边。
struct SignalPoster: View {
  let url: String?
  let signals: [ExternalHeatStore.DisplayRow]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var hovering = false
  @State private var sweepTrigger = UUID()

  private var hot: Bool { ExternalSignalPresentation.hasHeat(signals) }
  private var fingerprint: String { signals.map { "\($0.id):\($0.rank ?? 0):\($0.capturedAt ?? "")" }.joined(separator: "|") }

  var body: some View {
    let animateSweep = hot && !reduceMotion && scenePhase == .active
    return PosterImage(url: url, hovering: hovering)
      .overlay {
        if !signals.isEmpty {
          RoundedRectangle(cornerRadius: Theme.radiusPoster)
            .strokeBorder(hot ? Theme.accent.opacity(0.85) : Color.white.opacity(0.22), lineWidth: hot ? 1.5 : 1)
            .shadow(color: hot ? Theme.accent.opacity(hovering ? 0.4 : 0.18) : .clear, radius: hovering ? 9 : 5)
        }
      }
      .keyframeAnimator(initialValue: 0.0, trigger: sweepTrigger) { content, progress in
        content.overlay {
          if animateSweep {
            RoundedRectangle(cornerRadius: Theme.radiusPoster)
              .trim(from: max(0, progress - 0.2), to: progress)
              .stroke(LinearGradient(colors: [Theme.accent.opacity(0), .white, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .shadow(color: Theme.accent.opacity(0.7), radius: 5)
              .opacity(progress > 0 && progress < 1 ? 1 : 0)
              .allowsHitTesting(false)
          }
        }
      } keyframes: { _ in
        LinearKeyframe(0, duration: 0.01)
        LinearKeyframe(1, duration: 1.05)
      }
      .scaleEffect(hovering && !reduceMotion && scenePhase == .active ? 1.018 : 1)
      .offset(y: hovering && !reduceMotion && scenePhase == .active ? -2 : 0)
      .animation(.spring(response: 0.32, dampingFraction: 0.8), value: hovering)
      .onHover { value in
        hovering = value
        if value && hot && !reduceMotion && scenePhase == .active { sweepTrigger = UUID() }
      }
      .onChange(of: fingerprint) { old, _ in
        if !old.isEmpty && signals.contains(where: { ExternalSignalPresentation.rise($0) != nil }) && !reduceMotion && scenePhase == .active {
          sweepTrigger = UUID()
        }
      }
  }
}

struct ExternalSignalBadge: View {
  let signals: [ExternalHeatStore.DisplayRow]
  @State private var expanded = false
  @Environment(AppModel.self) private var app

  var body: some View {
    if !signals.isEmpty {
      Button { expanded.toggle() } label: {
        HStack(spacing: 5) {
          Image(systemName: ExternalSignalPresentation.hasHeat(signals) ? "flame.fill" : "chart.bar.xaxis")
          Text(ExternalSignalPresentation.label(signals)).lineLimit(1)
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(ExternalSignalPresentation.hasHeat(signals) ? Theme.accent : Theme.textSecondary)
        .padding(.vertical, 5).padding(.horizontal, 7)
        .background(Theme.elevated.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
      }
      .buttonStyle(.plain)
      .popover(isPresented: $expanded) {
        ScrollView {
          ExternalSignalsPanel(signals: signals) { signal in
            expanded = false
            app.openExternal(signal)
          }.padding(18)
        }.frame(width: 340).frame(maxHeight: 400)
      }
      .help("查看各来源的榜单与采集时间")
    }
  }
}

struct ExternalSignalsPanel: View {
  let signals: [ExternalHeatStore.DisplayRow]
  let open: (ExternalHeatStore.DisplayRow) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Theme.accent)
        Text("外部榜单").font(.system(size: 13, weight: .bold))
        Spacer()
        Text("保留各榜口径").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
      }
      ForEach(signals) { signal in
        let fresh = ExternalSignalPresentation.isFresh(signal)
        Button { open(signal) } label: {
          HStack(alignment: .top, spacing: 10) {
            Text(signal.rank.map { "#\($0)" } ?? "—")
              .font(.system(size: 17, weight: .bold).monospacedDigit())
              .foregroundStyle(fresh && ExternalSignalPresentation.isHeat(signal.source) ? Theme.accent : Theme.textSecondary)
              .frame(width: 43, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
              Text(ExternalSignalMeaning.label(for: signal.source)).font(.system(size: 11, weight: .semibold))
              Text([signal.rankingScope, signal.window, signal.region, signal.rankingEntryLabel].compactMap { $0 }.filter { !$0.isEmpty }.map(displayLabel).joined(separator: " · "))
                .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary)
              Text((fresh ? "采集 " : "较早记录 · ") + ExternalHeatTabView.shortTime(signal.capturedAt))
                .font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 2)
            if let rise = ExternalSignalPresentation.rise(signal) {
              Text("↑\(rise)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
            }
            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }.buttonStyle(.plain).help("打开对应来源榜单并定位作品")
        if signal.id != signals.last?.id { Divider().overlay(Theme.hairline) }
      }
    }.foregroundStyle(Theme.textPrimary)
  }

  private func displayLabel(_ value: String) -> String {
    ["overall": "综合", "movie": "电影", "series": "剧集", "tv": "剧集",
     "current": "当前榜", "upcoming": "待播", "day": "日榜", "week": "周榜",
     "month": "月榜", "CN": "中国大陆", "US": "美国", "global": "全球"][value] ?? value
  }
}

struct UpcomingScheduleList: View {
  let releases: [UpcomingRelease]
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("上线安排", systemImage: "calendar").font(.system(size: 13, weight: .bold))
      ForEach(releases) { release in
        if let url = URL(string: release.sourceURL) {
          Link(destination: url) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(release.source.title).font(.system(size: 11, weight: .semibold))
                Text(release.region == "US" ? "美国 · 数字付费 · 报道排期" : "中国大陆 · 北京时间")
                  .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                if release.region == "US" { Text("官宣状态未核实").font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 4) {
                Text(release.releaseDate ?? "待定档").font(.system(size: 12, weight: .semibold).monospacedDigit())
                if release.releaseDate != nil { Text(release.timeText).font(.system(size: 11).monospacedDigit()) }
              }.foregroundStyle(release.releaseTime == nil ? Theme.textSecondary : Theme.accent)
              Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }.padding(10).background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
          }.buttonStyle(.plain).help(release.rawSchedule)
        }
      }
    }
  }
}
