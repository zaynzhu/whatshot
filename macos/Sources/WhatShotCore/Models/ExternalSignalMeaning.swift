/// 保留榜单原始语义；待播顺序与口碑名次不表示动态热度。
public enum ExternalSignalMeaning {
  public static func label(for source: String) -> String {
    switch source {
    case "apple_tv_plus_news": return "Apple TV+ · 官方资讯"
    case "bilibili_rank": return "哔哩哔哩 · 排行榜"
    case "imdb_rating": return "IMDb · 评分"
    case "iqiyi_reserve": return "爱奇艺 · 预约"
    case "netflix_top10": return "奈飞 · 前十榜"
    case "tencent_reserve": return "腾讯视频 · 预约"
    case "tmdb_trending": return "TMDB · 电影趋势"
    case "tmdb_tv_trending": return "TMDB · 剧集趋势"
    case "trakt_anticipated": return "Trakt · 期待榜"
    case "trakt_trending": return "Trakt · 趋势榜"
    case "youku_hot": return "优酷 · 热度"
    case "youku_reserve": return "优酷 · 预约"
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
