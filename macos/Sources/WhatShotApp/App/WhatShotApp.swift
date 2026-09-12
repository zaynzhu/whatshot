import SwiftUI
import WhatShotCore

/// 应用入口：普通窗口应用（WhatsNew 同款形态）。
/// 菜单栏形态（MenuBarExtra / NSStatusItem）在这台 macOS 26 上状态项不可见，已放弃。
@main
struct WhatShotAppMain: App {
  @State private var appModel = AppModel()

  var body: some Scene {
    WindowGroup("WhatShot") {
      ContentView()
        .environment(appModel)
        .frame(minWidth: 620, minHeight: 480)
        .task {
          await appModel.bootstrapIfNeeded()
        }
    }
    .defaultSize(width: 900, height: 640)
  }
}
