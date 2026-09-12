import AppKit
import Foundation
import WhatShotCore

/// 海报加载器：NSCache 内存缓存 + 磁盘缓存（有上限、LRU 淘汰）
/// 内存压力时 NSCache 自动逐出，磁盘上限默认跟随设置
final class PosterLoader: @unchecked Sendable {
  static let shared = PosterLoader()

  private let memoryCache = NSCache<NSURL, NSImage>()
  private let diskDir: URL
  private let limitBytes: Int64
  private let ioQueue = DispatchQueue(label: "whatshot.poster", qos: .utility)

  init(limitMB: Int = 300) {
    memoryCache.totalCostLimit = 40 * 1024 * 1024 // 内存中最多约 40MB 海报
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WhatShot/posters", isDirectory: true)
    try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    diskDir = caches
    limitBytes = Int64(max(0, limitMB)) * 1024 * 1024
  }

  func load(_ url: URL) async -> NSImage? {
    if let cached = memoryCache.object(forKey: url as NSURL) {
      return cached
    }
    let key = url.absoluteString.sha1Hex()
    let fileURL = diskDir.appendingPathComponent(key)
    if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
      // 磁盘缓存里的历史数据可能含图床占位图，读出后同样过滤
      if PosterLoader.isPlaceholder(image) {
        memoryCache.setObject(PosterLoader.placeholderSentinel, forKey: url as NSURL, cost: 1)
        return nil
      }
      memoryCache.setObject(image, forKey: url as NSURL, cost: image.pixelBytes)
      touch(fileURL)
      return image
    }
    // 网络拉取：海报走独立并发通道，不占用接口限频额度（不同主机不同服务）
    guard let (data, response) = try? await URLSession.shared.data(from: url),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let image = NSImage(data: data) else {
      return nil
    }
    // 图床对失效海报返回 HTTP 200 的默认占位图（白底爆米花），必须拦截，否则永久缓存
    guard !PosterLoader.isPlaceholder(image) else {
      memoryCache.setObject(PosterLoader.placeholderSentinel, forKey: url as NSURL, cost: 1)
      return nil
    }
    memoryCache.setObject(image, forKey: url as NSURL, cost: image.pixelBytes)
    let cost = image.pixelBytes
    ioQueue.async {
      try? data.write(to: fileURL, options: .atomic)
      self.enforceLimit(cost: cost)
    }
    return image
  }

  /// 图床默认占位图特征：300x420、画面整体接近纯白（中心 40x40 采样均值 > 0.85 亮度）
  static func isPlaceholder(_ image: NSImage) -> Bool {
    guard let rep = image.representations.first, rep.pixelsWide == 300, rep.pixelsHigh == 420 else {
      return false
    }
    return image.meanLuminance(centerBox: 40) > 0.85
  }

  /// 占位图负缓存标记：命中过占位的 URL 短期内不再重复网络请求
  static let placeholderSentinel = NSImage(size: NSSize(width: 1, height: 1))

  /// 磁盘占用（字节）：设置页展示用，扫目录文件大小
  func diskUsageBytes() -> Int64 {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: diskDir, includingPropertiesForKeys: [.fileSizeKey]
    )) ?? []
    return files.reduce(Int64(0)) { total, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return total + Int64(size)
    }
  }

  /// 磁盘 LRU：超上限按最旧访问时间淘汰
  private func enforceLimit(cost: Int) {
    guard limitBytes > 0 else { return }
    let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey])) ?? []
    var total: Int64 = 0
    let infos: [(url: URL, date: Date, size: Int64)] = files.compactMap { fileURL in
      guard let values = try? fileURL.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey]) else { return nil }
      let size = Int64(values.fileSize ?? 0)
      total += size
      return (fileURL, values.contentAccessDate ?? .distantPast, size)
    }
    guard total > limitBytes else { return }
    let over = total - limitBytes + Int64(Double(limitBytes) * 0.1) // 多清 10% 避免频繁触发
    var removed: Int64 = 0
    for info in infos.sorted(by: { $0.date < $1.date }) {
      guard removed < over else { break }
      try? FileManager.default.removeItem(at: info.url)
      removed += info.size
    }
  }

  private func touch(_ fileURL: URL) {
    ioQueue.async {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }
  }
}

extension NSImage {
  var pixelBytes: Int {
    guard let rep = representations.first else { return 64 * 1024 }
    return rep.pixelsWide * rep.pixelsHigh * 4
  }

  /// 中心区域平均亮度（0~1）：用于占位图检测，只采样中心小块避免全图扫描
  func meanLuminance(centerBox: Int) -> Double {
    guard let rep = representations.first,
          let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return 0
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let box = min(centerBox, w, h)
    let rect = CGRect(x: (w - box) / 2, y: (h - box) / 2, width: box, height: box)
    guard let cropped = cgImage.cropping(to: rect) else { return 0 }
    var pixels = [UInt8](repeating: 0, count: box * box * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: box, height: box, bitsPerComponent: 8,
                              bytesPerRow: box * 4, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      return 0
    }
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: box, height: box))
    var total = 0.0
    let count = box * box
    for i in 0..<count {
      total += (Double(pixels[i*4]) + Double(pixels[i*4+1]) + Double(pixels[i*4+2])) / (3.0 * 255.0)
    }
    return total / Double(count)
  }
}

extension String {
  func sha1Hex() -> String {
    // 轻量 SHA-1：仅做缓存文件名，非安全用途
    let data = Data(self.utf8)
    var hash = [UInt32](repeating: 0, count: 5)
    var w = [UInt32](repeating: 0, count: 80)
    var message = data.map { $0 }
    let originalBitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8((originalBitLength >> UInt64(shift)) & 0xFF))
    }
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      for i in 0..<16 {
        let start = chunkStart + i * 4
        w[i] = (UInt32(message[start]) << 24) | (UInt32(message[start+1]) << 16) | (UInt32(message[start+2]) << 8) | UInt32(message[start+3])
      }
      for i in 16..<80 {
        w[i] = rotateLeft(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1)
      }
      var a: UInt32 = hash[0], b: UInt32 = hash[1], c: UInt32 = hash[2], d: UInt32 = hash[3], e: UInt32 = hash[4]
      for i in 0..<80 {
        var f: UInt32
        var k: UInt32
        switch i {
        case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
        case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
        case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
        default: f = b ^ c ^ d; k = 0xCA62C1D6
        }
        let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
        e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
      }
      hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b; hash[2] = hash[2] &+ c
      hash[3] = hash[3] &+ d; hash[4] = hash[4] &+ e
    }
    return hash.map { String(format: "%08x", $0) }.joined()
  }

  private func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
    (value << amount) | (value >> (32 - amount))
  }
}