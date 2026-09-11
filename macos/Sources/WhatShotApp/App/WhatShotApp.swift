import AppKit
import SwiftUI
import WhatShotCore

/// 应用入口：NSStatusItem + NSPopover 菜单栏应用（LSUIElement）。
/// 不用 SwiftUI MenuBarExtra——实测 macOS 26 上状态项不挂载（连最小 demo 都不显示）。
@main
final class WhatShotAppMain: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var appModel: AppModel?
  private var eventMonitor: Any?

  static func main() {
    let app = NSApplication.shared
    let delegate = WhatShotAppMain()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // 无 Dock 图标
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = AppModel()
    appModel = model

    let contentView = ContentView()
      .environment(model)
      .frame(width: 640, height: 520)

    let popover = NSPopover()
    popover.contentViewController = NSHostingController(rootView: contentView)
    popover.behavior = .transient // 点外部自动收起
    self.popover = popover

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "WhatShot")
    item.button?.target = self
    item.button?.action = #selector(togglePopover(_:))
    statusItem = item

    // 点击面板外部时关闭
    eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      if self?.popover.isShown == true {
        self?.popover.performClose(nil)
      }
    }

    Task { await model.bootstrapIfNeeded() }
  }

  private var popover: NSPopover!

  @objc func togglePopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
    }
  }
}
