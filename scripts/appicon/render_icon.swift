// WhatShot 应用图标渲染脚本「深夜画廊·档案版」
// 构图 = 琥珀火焰（WhatShot 的热度符号）+ 底部集数进度线（追剧进度叙事）
// 满幅方形画布：macOS 26 会自动套用系统 squircle 遮罩，不自带圆角与透明边
// 图标在台前调度栏（暗背景）中必须可辨识：火焰占大幅 + 底部光晕托底，
// 32px 下琥珀像素占比 >35%，深底不再融进栏背景
// 用法: swift render_icon.swift <输出路径.png>

import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write("用法: swift render_icon.swift <输出路径>\n".data(using: .utf8)!)
  exit(1)
}
let outputPath = args[1]

// MARK: - 主题（与 DesignSystem.swift 严格同源）

let bgColor = NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x13 / 255, alpha: 1)   // #101013
let accent = NSColor(srgbRed: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)    // #D9A441
let accentBright = NSColor(srgbRed: 0xF0 / 255, green: 0xBE / 255, blue: 0x62 / 255, alpha: 1) // #F0BE62 小尺寸提亮

// MARK: - 位图上下文

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: size, height: size)
let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let cg = graphicsContext.cgContext

// MARK: - 背景：满幅深底 + 底部琥珀地板光（台前调度栏暗背景下仍能看出图标轮廓）

cg.setFillColor(bgColor.cgColor)
cg.fill(CGRect(x: 0, y: 0, width: size, height: size))

let glowCenter = CGPoint(x: size * 0.5, y: -size * 0.10)
let accentCG = CGColor(srgbRed: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)
let glowColors = [accentCG.copy(alpha: 0.34)!, accentCG.copy(alpha: 0)!] as CFArray
let glowSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let glow = CGGradient(colorsSpace: glowSpace, colors: glowColors, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                      endCenter: glowCenter, endRadius: size * 0.72, options: [])

// MARK: - 主角：琥珀火焰（SF Symbol flame.fill），大幅占中确保 16px 仍可辨认

let flameRect = CGRect(x: 0, y: 0, width: size * 0.72, height: size * 0.72)
let baseSymbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)!
let tinted = baseSymbol.withSymbolConfiguration(
  NSImage.SymbolConfiguration(paletteColors: [accentBright])
)!
// 火焰按原始比例缩放绘制，居中略偏上（给底部进度线留呼吸位）
let symbolSize = tinted.size
let scale = min(flameRect.width / symbolSize.width, flameRect.height / symbolSize.height)
let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
let drawOrigin = NSPoint(
  x: size / 2 - drawSize.width / 2,
  y: size * 0.56 - drawSize.height / 2
)
tinted.draw(in: NSRect(origin: drawOrigin, size: drawSize))

// MARK: - 底部集数进度线：琥珀段（进行中 78%）+ 灰底轨，紧贴火焰下缘形成一体叙事

let trackY = size * 0.17
let trackStart = size * 0.24
let trackEnd = size * 0.76
let trackHeight = size * 0.020

cg.setLineCap(.round)

cg.move(to: CGPoint(x: trackStart, y: trackY))
cg.addLine(to: CGPoint(x: trackEnd, y: trackY))
cg.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
cg.setLineWidth(trackHeight)
cg.strokePath()

cg.move(to: CGPoint(x: trackStart, y: trackY))
cg.addLine(to: CGPoint(x: trackStart + (trackEnd - trackStart) * 0.78, y: trackY))
cg.setStrokeColor(accentBright.cgColor)
cg.setLineWidth(trackHeight)
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()

// MARK: - 输出 PNG

guard let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
  exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Rendered \(outputPath)")