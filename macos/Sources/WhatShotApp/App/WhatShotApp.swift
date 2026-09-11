import SwiftUI
import WhatShotCore

/// 应用入口：菜单栏应用（LSUIElement），点开面板才渲染界面
@main
struct WhatShotAppMain: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var appModel = AppModel()

  var body: some Scene {
    MenuBarExtra {
      ContentView()
        .environment(appModel)
        .frame(width: 640, height: 520)
    } label: {
      Image(systemName: "flame.fill")
    }
    .menuBarExtraStyle(.window)
  }
}

/// 生命周期：启动时收尾中断同步 + 按需启动定时同步
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task.detached(priority: .background) {
      await AppModel.sharedBootstrap()
    }
  }
}