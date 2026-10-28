import Foundation

/// 仅解码 Nuxt 序列化字面量，不运行 JavaScript；函数调用、属性访问、运算均不在语法内。
enum NuxtLiteral {
  static func decode(_ html: String) throws -> [String: Any] {
    guard html.utf8.count <= 4_000_000,
          let start = html.range(of: "window.__NUXT__="),
          let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
      throw UpcomingError("爱奇艺页面缺少待播数据")
    }
    var reader = Reader(String(html[start.upperBound..<end.lowerBound]))
    try reader.consume("(function(")
    var names: [String] = []
    if !reader.peek(")") {
      repeat {
        names.append(try reader.identifier())
        guard names.count <= 1024 else { throw reader.invalid }
        if !reader.peek(",") { break }
        try reader.consume(",")
      } while true
    }
    guard Set(names).count == names.count else { throw reader.invalid }
    try reader.consume("){return")
    let body = try reader.objectBytes()
    try reader.consume("}(")
    var arguments: [Any] = []
    if !reader.peek(")") {
      repeat {
        arguments.append(try reader.value())
        if !reader.peek(",") { break }
        try reader.consume(",")
      } while true
    }
    try reader.consume("))")
    if reader.peek(";") { try reader.consume(";") }
    guard reader.atEnd, names.count == arguments.count else { throw reader.invalid }
    var payload = Reader(body, bindings: Dictionary(uniqueKeysWithValues: zip(names, arguments)))
    guard let result = try payload.value() as? [String: Any], payload.atEnd else { throw reader.invalid }
    return result
  }

  private struct Reader {
    var bytes: [UInt8]
    var offset = 0
    var bindings: [String: Any]
    var invalid: UpcomingError { UpcomingError("爱奇艺待播数据格式变化，已保留上次数据") }

    init(_ text: String, bindings: [String: Any] = [:]) {
      self.bytes = Array(text.utf8)
      self.bindings = bindings
    }

    mutating func whitespace() {
      while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    var atEnd: Bool {
      mutating get { whitespace(); return offset == bytes.count }
    }
    mutating func peek(_ text: String) -> Bool {
      whitespace()
      return bytes.dropFirst(offset).starts(with: text.utf8)
    }
    mutating func consume(_ text: String) throws {
      guard peek(text) else { throw invalid }
      offset += text.utf8.count
    }
    mutating func identifier() throws -> String {
      whitespace()
      let start = offset
      while offset < bytes.count {
        let byte = bytes[offset]
        guard (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36
                || (offset > start && (48...57).contains(byte)) else { break }
        offset += 1
      }
      guard offset > start else { throw invalid }
      return String(decoding: bytes[start..<offset], as: UTF8.self)
    }
    mutating func string() throws -> String {
      try consume("\"")
      let start = offset - 1
      while offset < bytes.count {
        let byte = bytes[offset]
        offset += 1
        if byte == 92 { offset += 1 }
        if byte == 34 {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
        }
      }
      throw invalid
    }
    mutating func objectBytes() throws -> String {
      whitespace()
      let start = offset
      guard peek("{") else { throw invalid }
      var depth = 0
      while offset < bytes.count {
        if bytes[offset] == 34 { _ = try string(); continue }
        let byte = bytes[offset]
        offset += 1
        if byte == 123 { depth += 1 }
        if byte == 125 {
          depth -= 1
          if depth == 0 { return String(decoding: bytes[start..<offset], as: UTF8.self) }
        }
        guard depth <= 64 else { throw invalid }
      }
      throw invalid
    }
    mutating func value(depth: Int = 0) throws -> Any {
      whitespace()
      guard offset < bytes.count, depth < 64 else { throw invalid }
      if peek("\"") { return try string() }
      if peek("{") {
        try consume("{")
        var result: [String: Any] = [:]
        if !peek("}") {
          repeat {
            let key = peek("\"") ? try string() : try identifier()
            guard result[key] == nil else { throw invalid }
            try consume(":")
            result[key] = try value(depth: depth + 1)
            if !peek(",") { break }
            try consume(",")
          } while true
        }
        try consume("}")
        return result
      }
      if peek("[") {
        try consume("[")
        var result: [Any] = []
        if !peek("]") {
          repeat {
            result.append(try value(depth: depth + 1))
            if !peek(",") { break }
            try consume(",")
          } while true
        }
        try consume("]")
        return result
      }
      if bytes[offset] == 45 || (48...57).contains(bytes[offset]) {
        let start = offset
        while offset < bytes.count && "-+0123456789.eE".utf8.contains(bytes[offset]) { offset += 1 }
        let number = String(decoding: bytes[start..<offset], as: UTF8.self)
        if let value = Int64(number) { return value }
        guard let value = Double(number), value.isFinite else { throw invalid }
        return value
      }
      let name = try identifier()
      switch name {
      case "null", "undefined": return NSNull()
      case "true": return true
      case "false": return false
      case "void": try consume("0"); return NSNull()
      default:
        guard let value = bindings[name] else { throw invalid }
        return value
      }
    }
  }
}
