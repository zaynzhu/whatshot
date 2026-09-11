import SwiftUI
import WhatShotCore

/// 设置页：深色卡片分组，无系统 Form 默认样式
struct SettingsTabView: View {
  @Environment(AppModel.self) private var app
  @State private var draft: ButaiSettings = .default
  @State private var saved = false

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        settingCard(title: "数据源", icon: "globe") {
          VStack(alignment: .leading, spacing: 8) {
            Text("站点地址")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Theme.textSecondary)
            TextField("https://www.butai0.club", text: $draft.baseURL)
              .textFieldStyle(.plain)
              .font(.system(size: 13, design: .rounded))
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: Theme.radiusChip)
                  .fill(Theme.bg)
                  .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusChip)
                      .stroke(Theme.hairline, lineWidth: 1)
                  )
              )
              .foregroundStyle(Theme.textPrimary)
            Text("站点域名经常更换时，改成新的备用域名即可")
              .font(.system(size: 11))
              .foregroundStyle(Theme.textTertiary)
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
        }

        HStack {
          Spacer()
          if saved {
            Label("已保存", systemImage: "checkmark.circle.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Theme.douban)
              .transition(.opacity)
          }
          Button {
            Task {
              await app.updateSettings(draft)
              withAnimation(.easeOut(duration: 0.2)) { saved = true }
              try? await Task.sleep(nanoseconds: 1_500_000_000)
              withAnimation(.easeIn(duration: 0.3)) { saved = false }
            }
          } label: {
            Text("保存设置")
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 22)
              .padding(.vertical, 8)
              .background(Capsule().fill(Theme.accent))
              .foregroundStyle(.white)
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 4)
      }
      .padding(20)
    }
    .background(Theme.bg)
    .onAppear { draft = app.settings }
  }

  /// 设置分组卡
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
        .fill(Theme.card)
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

  private func stepperBadge(value: Binding<Int>, suffix: String) -> some View {
    HStack(spacing: 10) {
      Button {
        if value.wrappedValue > 1 { value.wrappedValue -= 1 }
      } label: {
        Image(systemName: "minus")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 20, height: 20)
          .background(Circle().fill(Theme.bg))
          .foregroundStyle(Theme.textSecondary)
      }
      .buttonStyle(.plain)

      Text("\(value.wrappedValue) \(suffix)")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.textPrimary)
        .frame(minWidth: 38)

      Button {
        if value.wrappedValue < 10 { value.wrappedValue += 1 }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 20, height: 20)
          .background(Circle().fill(Theme.bg))
          .foregroundStyle(Theme.textSecondary)
      }
      .buttonStyle(.plain)
    }
  }
}