import SwiftUI
import WhatShotCore

/// 设置页：浮层卡片分组 + hairline 描边控件，与画廊主题同套 token
struct SettingsTabView: View {
  @Environment(AppModel.self) private var app
  @State private var draft: ButaiSettings = .default
  @State private var saved = false
  // 磁盘占用：进页算一次，字节
  @State private var posterCacheBytes: Int64 = 0
  @State private var databaseBytes: Int64 = 0

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        PageHeader(eyebrow: "PREFERENCES", title: "设置", subtitle: "数据与设置仅存本机，不上传")
          .padding(.bottom, 2)

        settingCard(title: "数据源", icon: "globe") {
          VStack(alignment: .leading, spacing: 8) {
            Text("站点地址")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Theme.textSecondary)
            TextField("https://www.butai0.club", text: $draft.baseURL)
              .textFieldStyle(.plain)
              .font(.system(size: 13).monospacedDigit())
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                  .fill(Theme.bg)
                  .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                      .stroke(Theme.hairline, lineWidth: 1)
                  )
              )
              .foregroundStyle(Theme.textPrimary)
            Text("站点域名经常更换时，改成新的备用域名即可；留空则自动从发布页发现官方域名")
              .font(.system(size: 11))
              .foregroundStyle(Theme.textTertiary)
            // 状态行始终展示：无路由数据时显示"待同步"，不让用户误读成发布页故障
            if let probe = app.currentProbe {
              HStack(spacing: 6) {
                Circle()
                  .fill(Theme.accent)
                  .frame(width: 5, height: 5)
                Text("当前路由 \(URL(string: probe.baseURL)?.host ?? probe.baseURL) · \(Int(probe.latency * 1000)) ms")
                  .font(.system(size: 11).monospacedDigit())
                  .foregroundStyle(Theme.textSecondary)
              }
            } else {
              HStack(spacing: 6) {
                Circle()
                  .fill(Theme.textTertiary)
                  .frame(width: 5, height: 5)
                Text("尚未同步，路由信息将在首次同步后展示")
                  .font(.system(size: 11))
                  .foregroundStyle(Theme.textTertiary)
              }
            }
            DomainPoolSection(
              published: app.lastPublishedDomains,
              pinnedDomain: $draft.pinnedDomain,
              currentHost: app.currentProbe.flatMap { URL(string: $0.baseURL)?.host },
              onPin: { pinned in
                // 点选即保存（不等底部"保存设置"：钉域名是即时路由偏好，与同步间隔等配置不同类）
                var next = draft
                next.pinnedDomain = pinned
                draft = next
                Task { await app.updateSettings(next) }
              }
            )
          }
        }

        settingCard(title: "同步", icon: "arrow.triangle.2.circlepath") {
          VStack(alignment: .leading, spacing: 12) {
            pickerRow(label: "自动同步间隔") {
              Picker("", selection: $draft.syncIntervalHours) {
                Text("关闭").tag(0)
                ForEach([1, 2, 3, 6, 12, 24], id: \.self) { hours in
                  Text(hours == 1 ? "每小时" : "每 \(hours) 小时").tag(hours)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .tint(Theme.textPrimary)
            }
            pickerRow(label: "电影抓取页数") {
              stepperBadge(value: $draft.movieListPages, suffix: "页")
            }
            pickerRow(label: "剧集抓取页数") {
              stepperBadge(value: $draft.tvListPages, suffix: "页")
            }
          }
        }

        settingCard(title: "缓存", icon: "internaldrive") {
          VStack(alignment: .leading, spacing: 10) {
            pickerRow(label: "海报磁盘缓存上限") {
              Picker("", selection: $draft.posterCacheLimitMB) {
                Text("关闭").tag(0)
                ForEach([100, 200, 300, 500], id: \.self) { mb in
                  Text("\(mb) MB").tag(mb)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .tint(Theme.textPrimary)
            }
            diskUsageRow
          }
        }

        HStack {
          Spacer()
          if saved {
            Label("已保存", systemImage: "checkmark.circle.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.green.opacity(0.85))
              .transition(.opacity)
          }
          AccentButton(title: "保存设置") {
            Task {
              await app.updateSettings(draft)
              withAnimation(.easeOut(duration: 0.2)) { saved = true }
              try? await Task.sleep(nanoseconds: 1_500_000_000)
              withAnimation(.easeIn(duration: 0.3)) { saved = false }
            }
          }
        }
        .padding(.top, 4)
      }
      .padding(20)
    }
    .background(Theme.bg)
    .onAppear {
      draft = app.settings
      refreshDiskUsage()
    }
  }

  /// 磁盘占用行：海报缓存 + 数据库分项，合计附 1px 细进度线（缓存/上限比值，关闭上限时不画）
  /// 上限调低后立即反映：用 draft.posterCacheLimitMB 计算
  private var diskUsageRow: some View {
    let limitBytes = Int64(draft.posterCacheLimitMB) * 1024 * 1024
    let ratio = limitBytes > 0 ? min(1, Double(posterCacheBytes) / Double(limitBytes)) : nil

    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("当前占用")
          .font(.system(size: 12.5))
          .foregroundStyle(Theme.textSecondary)
        Spacer()
        Text("海报 \(Self.formatted(posterCacheBytes)) · 数据库 \(Self.formatted(databaseBytes))")
          .font(.system(size: 12, weight: .semibold).monospacedDigit())
          .foregroundStyle(Theme.textPrimary)
      }
      HStack(spacing: 8) {
        if let ratio {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Rectangle().fill(Theme.hairline)
              Rectangle()
                .fill(ratio >= 0.9 ? Theme.accent : Theme.textTertiary)
                .frame(width: max(2, geo.size.width * ratio))
            }
          }
          .frame(height: 1.5)
          Text("上限 \(draft.posterCacheLimitMB) MB · \(Int(ratio * 100))%")
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(ratio >= 0.9 ? Theme.accent : Theme.textTertiary)
        } else {
          Text("未设上限，缓存随访问自动增长")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary)
        }
      }
    }
  }

  private func refreshDiskUsage() {
    posterCacheBytes = PosterLoader.shared.diskUsageBytes()
    databaseBytes = Self.fileSize(at: SharedRuntime.databasePath())
      + Self.fileSize(at: SharedRuntime.databasePath() + "-wal")
      + Self.fileSize(at: SharedRuntime.databasePath() + "-shm")
  }

  private static func fileSize(at path: String) -> Int64 {
    let url = URL(fileURLWithPath: path)
    return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  private static func formatted(_ bytes: Int64) -> String {
    bytes >= 1024 * 1024
      ? String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
      : "\(max(0, Int(bytes) / 1024)) KB"
  }

  /// 设置分组卡：浮层底 + hairline 描边
  private func settingCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: icon)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusCard)
        .fill(Theme.elevated)
        .overlay(
          RoundedRectangle(cornerRadius: Theme.radiusCard)
            .stroke(Theme.hairline, lineWidth: 1)
        )
    )
  }

  private func pickerRow<Content: View>(label: String, @ViewBuilder control: () -> Content) -> some View {
    HStack {
      Text(label)
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textSecondary)
      Spacer()
      control()
    }
  }

  /// 步进器：方角描边按钮 + 等宽计数
  private func stepperBadge(value: Binding<Int>, suffix: String) -> some View {
    HStack(spacing: 10) {
      Button {
        if value.wrappedValue > 1 { value.wrappedValue -= 1 }
      } label: {
        Image(systemName: "minus")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 22, height: 22)
          .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
              .stroke(Theme.hairline, lineWidth: 1)
          )
          .foregroundStyle(Theme.textSecondary)
      }
      .buttonStyle(.plain)

      Text("\(value.wrappedValue) \(suffix)")
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(Theme.textPrimary)
        .frame(minWidth: 38)

      Button {
        if value.wrappedValue < 10 { value.wrappedValue += 1 }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 22, height: 22)
          .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
              .stroke(Theme.hairline, lineWidth: 1)
          )
          .foregroundStyle(Theme.textSecondary)
      }
      .buttonStyle(.plain)
    }
  }
}

/// 官方域名池区块：收起时一行状态（发布页发现 N 个），展开列出全部域名。
/// 点选域名 = 钉住（跳过探活直接用，失败仍自动降级）；再点已钉住的 = 取消回自动。
/// 钉住/取消即时保存，不等底部「保存设置」
struct DomainPoolSection: View {
  let published: [String]?
  @Binding var pinnedDomain: String?
  let currentHost: String?
  let onPin: (String?) -> Void
  @State private var expanded = false

  private var domains: [String] {
    // 发布页结果优先展示（可能含兜底池外新域名）；不可达时展示兜底池
    (published?.isEmpty == false ? published! : DomainPool.fallbackDomains)
  }

  private var headline: String {
    if published == nil {
      return "发布页不可达，展示内置兜底池（\(DomainPool.fallbackDomains.count) 域名）"
    }
    let extra = published!.filter { !DomainPool.fallbackDomains.contains($0) }.count
    let extraNote = extra > 0 ? "（含 \(extra) 个兜底池外新域名）" : ""
    return "发布页发现 \(published!.count) 个官方域名\(extraNote)，点击可固定使用"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Circle()
            .fill(published == nil ? Theme.textTertiary : Theme.accent)
            .frame(width: 5, height: 5)
          Text(headline)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .foregroundStyle(Theme.textTertiary)
        }
      }
      .buttonStyle(.plain)

      if expanded {
        VStack(alignment: .leading, spacing: 0) {
          // 自动档：钉住 nil = 探活择优（现状行为）
          domainRow(host: nil, label: "自动（每次探活选最快）") {
            onPin(nil)
          }
          Rectangle().fill(Theme.hairline).frame(height: 1)
          ForEach(domains, id: \.self) { domain in
            domainRow(
              host: URL(string: DomainPool.normalized(domain) ?? domain)?.host ?? domain,
              label: nil
            ) {
              // 再点已钉住的 = 取消
              onPin(pinnedDomain == domain ? nil : domain)
            }
          }
        }
        .padding(.vertical, 4)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.radiusControl)
            .stroke(Theme.hairline, lineWidth: 1)
        )
      }
    }
  }

  /// 单行：钉住项琥珀点 + 主字色；当前路由加「当前」角标；nil host = 自动模式行
  private func domainRow(host: String?, label: String?, action: @escaping () -> Void) -> some View {
    let isPinned = pinnedDomain != nil && host == nil
    let isCurrentDomain = host != nil && host == currentHost && pinnedDomain == nil
    return Button(action: action) {
      HStack(spacing: 7) {
        Circle()
          .fill(isPinned ? Theme.accent : Color.clear)
          .frame(width: 4, height: 4)
        Text(label ?? host ?? "")
          .font(.system(size: 11, weight: isPinned || isCurrentDomain ? .semibold : .regular).monospacedDigit())
          .foregroundStyle(isPinned || isCurrentDomain ? Theme.textPrimary : Theme.textSecondary)
        if isCurrentDomain {
          Text("当前")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        if isPinned {
          Text("已固定")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        Spacer(minLength: 12)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5.5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
