// WhatShot 应用图标渲染脚本「深夜画廊·档案版」
// 构图 = 琥珀火焰（WhatShot 的热度符号）+ 底部集数进度线（追剧进度叙事）
// 满幅方形画布：macOS 26 会自动套用系统 squircle 遮罩，不自带圆角与透明边
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
let hairline = NSColor(white: 1, alpha: 0.08)

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

// MARK: - 背景：满幅深底 + 底部极淡琥珀地板光（唯一的"光"，强度压在可感知边缘）

cg.setFillColor(bgColor.cgColor)
cg.fill(CGRect(x: 0, y: 0, width: size, height: size))

let glowCenter = CGPoint(x: size * 0.5, y: -size * 0.38)
let accentCG = CGColor(srgbRed: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)
let glowColors = [accentCG.copy(alpha: 0.16)!, accentCG.copy(alpha: 0)!] as CFArray
let glowSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let glow = CGGradient(colorsSpace: glowSpace, colors: glowColors, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                      endCenter: glowCenter, endRadius: size * 0.95, options: [])

// MARK: - 主角：琥珀火焰（SF Symbol flame.fill，单色琥珀纪律）

let flameRect = CGRect(x: 0, y: 0, width: size * 0.52, height: size * 0.52)
let baseSymbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)!
let tinted = baseSymbol.withSymbolConfiguration(
  NSImage.SymbolConfiguration(paletteColors: [accent])
)!
// 火焰按原始比例缩放绘制，垂直居中略偏上（视觉重心）
let symbolSize = tinted.size
let scale = min(flameRect.width / symbolSize.width, flameRect.height / symbolSize.height)
let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
let drawOrigin = NSPoint(
  x: size / 2 - drawSize.width / 2,
  y: size * 0.545 - drawSize.height / 2
)
tinted.draw(in: NSRect(origin: drawOrigin, size: drawSize))

// MARK: - 底部集数进度线：琥珀段（进行中 78%）+ hairline 底轨，紧贴火焰下缘形成一体叙事

let trackY = size * 0.225
let trackStart = size * 0.345
let trackEnd = size * 0.655
let trackHeight = size * 0.014

cg.setLineCap(.round)

cg.move(to: CGPoint(x: trackStart, y: trackY))
cg.addLine(to: CGPoint(x: trackEnd, y: trackY))
cg.setStrokeColor(hairline.cgColor)
cg.setLineWidth(trackHeight)
cg.strokePath()

cg.move(to: CGPoint(x: trackStart, y: trackY))
cg.addLine(to: CGPoint(x: trackStart + (trackEnd - trackStart) * 0.78, y: trackY))
cg.setStrokeColor(accent.cgColor)
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