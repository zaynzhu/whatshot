/// 保留榜单原始语义；待播顺序与口碑名次不表示动态热度。
public enum ExternalSignalMeaning {
  public static func label(for source: String) -> String {
    switch source {
    case "douban_top": return "豆瓣 TOP250 · 口碑"
    case "douban_upcoming": return "豆瓣 · 待播顺序"
    case "douban_upcoming_hot": return "豆瓣 · 预约"
    default: return source
    }
  }

  public static func isDoubanNonHeat(_ source: String) -> Bool {
    ["douban_top", "douban_upcoming", "douban_upcoming_hot"].contains(source)
  }

  public static func explanation(for source: String) -> String? {
    switch source {
    case "douban_top": return "TOP250 口碑名次，不代表近期热度。"
    case "douban_upcoming": return "待播日期分组内的顺序，不是热度排名。"
    case "douban_upcoming_hot": return "电影与剧集分别统计的预约榜，不计入动态热度。"
    default: return nil
    }
  }
}
