import Foundation

/// 只处理当前待播的有限身份元数据，输出键供 SQL 在分页之前分组。
enum UpcomingGrouping {
  static func keys(rows: [UpcomingRelease], connections: [String: WorkConnection]) throws -> [String: String] {
    func key(_ parts: [String]) throws -> String {
      String(decoding: try JSONEncoder().encode(parts), as: UTF8.self)
    }
    var parents = Array(rows.indices)
    func root(_ index: Int) -> Int {
      var value = index
      while parents[value] != value { value = parents[value] }
      return value
    }
    var owners: [String: Int] = [:]
    var titleKeys: [String] = []
    for (index, row) in rows.enumerated() {
      let scope = [row.kind, row.region, row.releaseType]
      let titleKey = try key([row.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] + scope)
      titleKeys.append(titleKey)
      // 未返回连接意味着多重映射／身份冲突，不允许再经同名条目绕过保护。
      var candidates = [titleKey]
      if row.kind == "movie" {
        for (namespace, value) in connections[row.id]?.verifiedIDs ?? [:] {
          candidates.append(try key(["identity", namespace, value] + scope))
        }
      }
      for candidate in candidates {
        if let owner = owners[candidate] {
          let left = root(index)
          let right = root(owner)
          if left != right { parents[max(left, right)] = min(left, right) }
        } else { owners[candidate] = index }
      }
    }
    var groups: [Int: [Int]] = [:]
    for index in rows.indices { groups[root(index), default: []].append(index) }
    var result: [String: String] = [:]
    for indices in groups.values {
      var identities: [String: Set<String>] = [:]
      for index in indices {
        for (namespace, value) in connections[rows[index].id]?.verifiedIDs ?? [:] {
          identities[namespace, default: []].insert(value)
        }
      }
      let ambiguous = Set(indices.map { rows[$0].source }).count != indices.count
        || identities.values.contains { $0.count > 1 }
        || indices.contains { connections[rows[$0].id] == nil }
      if ambiguous {
        for index in indices { result[rows[index].id] = try key(["release", rows[index].id]) }
      } else if Set(indices.map { titleKeys[$0] }).count == 1 {
        // 保留已有同名分组键；包括没有核实身份的普通待播条目。
        let index = indices[0]
        result.merge(Dictionary(uniqueKeysWithValues: indices.map { (rows[$0].id, titleKeys[index]) })) { _, new in new }
      } else {
        let row = rows[indices[0]]
        let tokens = identities.map { "\($0.key):\($0.value.first!)" }.sorted()
        let groupKey = try key(["verified", row.kind, row.region, row.releaseType] + tokens)
        for index in indices { result[rows[index].id] = groupKey }
      }
    }
    return result
  }
}
