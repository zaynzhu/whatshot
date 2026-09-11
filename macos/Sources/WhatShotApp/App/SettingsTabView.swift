import SwiftUI
import WhatShotCore

/// 设置页：站点地址（域名可换）、同步间隔、缓存上限、抓取页数
struct SettingsTabView: View {
  @Environment(AppModel.self) private var app
  @State private var draft: ButaiSettings = .default
  @State private var saved = false

  var body: some View {
    Form {
      Section("数据源") {
        TextField("站点地址", text: $draft.baseURL)
          .textFieldStyle(.roundedBorder)
        Text("站点域名经常更换时，在这里改成新的备用域名即可")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("同步") {
        Picker("自动同步间隔", selection: $draft.syncIntervalHours) {
          Text("关闭").tag(0)
          ForEach([1, 2, 3, 6, 12, 24], id: \.self) { hours in
            Text(hours == 1 ? "每小时" : "每 \(hours) 小时").tag(hours)
          }
        }
        HStack {
          Text("列表抓取页数（每页 25 条）")
          Spacer()
          Stepper("电影 \((draft.movieListPages)) 页", value: $draft.movieListPages, in: 1...10)
            .fixedSize()
          Stepper("剧集 \((draft.tvListPages)) 页", value: $draft.tvListPages, in: 1...10)
            .fixedSize()
        }
      }

      Section("缓存") {
        Picker("海报磁盘缓存上限", selection: $draft.posterCacheLimitMB) {
          Text("关闭").tag(0)
          ForEach([100, 200, 300, 500], id: \.self) { mb in
            Text("\(mb) MB").tag(mb)
          }
        }
      }

      HStack {
        Spacer()
        if saved {
          Label("已保存", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.caption)
        }
        Button("保存设置") {
          Task {
            await app.updateSettings(draft)
            saved = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            saved = false
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear { draft = app.settings }
  }
}