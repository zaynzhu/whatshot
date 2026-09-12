import Foundation
import Testing
@testable import WhatShotCore

/// butai0 接口解析测试：字段容错、ejs 语义、榜单/列表两种结构
struct ButaiParserTests {
  /// 热门榜双层结构（getVideoList → data.data）
  @Test func parseVideoListNested() throws {
    let json = """
    {"requestId":"x","path":"/api/v1/getVideoList","success":true,"message":"请求成功","code":200,
     "data":{"data":[
       {"id":91223,"idcode":"35811064","title":"欢迎来龙餐馆","otitle":"","alias":"Once Upon A Time","image":"https://img.example/a.png","doub_id":35811064,"doub_score":"0","IMDB_number":"tt34386754","IMDB_score":"0","definition":"1080P蓝光","years":"2026","release":"2026(中国大陆)","class":"剧情,喜剧,战争","production_area":"中国大陆","episodes":"0","ejs":"","seed_num":2,"wp_num":1,"tp":1,"seed_updated_at":"2025-12-24 17:59:30","updated_at":"2026-07-08 12:17:31"},
       {"id":93370,"idcode":"37019104","title":"被追放的转生重骑士","doub_id":37019104,"doub_score":"7.8","episodes":"40","ejs":"更新至11集","seed_num":12,"wp_num":2,"tp":2}
     ]}}
    """
    let videos = try ButaiParser.parseVideoList(Data(json.utf8))
    #expect(videos.count == 2)
    #expect(videos[0].id == 91223)
    #expect(videos[0].kind == .movie)
    #expect(videos[0].doubanId == 35811064)
    #expect(videos[0].currentEpisode == nil)
    #expect(videos[1].episodeStatus == "更新至11集")
    #expect(videos[1].currentEpisode == 11)
    #expect(videos[1].episodeCount == 40)
    #expect(videos[1].doubanScore == "7.8")
  }

  /// 列表单层结构（getVideoMovieList → data.list），字段名不同（epic/niandai/eqxd）
  /// 分类以拉取来源 kind 为准：列表行无 tp 字段，站点电影页会混入剧集
  @Test func parseMovieListFlat() throws {
    let json = """
    {"success":true,"code":200,"data":{"page":1,"limit":25,"total":25124,"list":[
      {"doub_id":38462800,"id":93356,"aurl":"/mv/38462800","epic":"https://img.example/b.png","title":"直到T恤干透","ejs":"更新至9集","eqxd":"","niandai":"2026","imdbf":"0","alias":"T恤渐干","class":"剧情,爱情,悬疑","long_time":"","production_area":"日本","seed_num":34,"wp_num":4}
    ]}}
    """
    let videos = try ButaiParser.parseMovieList(Data(json.utf8), kind: .tvSeries)
    #expect(videos.count == 1)
    let video = videos[0]
    #expect(video.id == 93356)
    #expect(video.doubanId == 38462800)
    #expect(video.title == "直到T恤干透")
    #expect(video.episodeStatus == "更新至9集")
    #expect(video.currentEpisode == 9)
    #expect(video.posterURL == "https://img.example/b.png")
    #expect(video.seedCount == 34)
    #expect(video.netdiskCount == 4)
    #expect(video.kind == .tvSeries)
  }

  /// 同一列表行按电影来源解析时 kind 应为电影（站点电影页混入的剧集也按来源归类）
  @Test func parseMovieListKindFromSource() throws {
    let json = """
    {"success":true,"code":200,"data":{"list":[
      {"doub_id":100,"id":1,"title":"与萨曼莎·比正面交锋","ejs":"更新至35集"}
    ]}}
    """
    let movies = try ButaiParser.parseMovieList(Data(json.utf8), kind: .movie)
    #expect(movies[0].kind == .movie)
    let series = try ButaiParser.parseMovieList(Data(json.utf8), kind: .tvSeries)
    #expect(series[0].kind == .tvSeries)
  }

  /// "全集" 应解析出总集数作为当前集
  @Test func fullSeriesEpisode() throws {
    let json = """
    {"success":true,"code":200,"data":{"list":[
      {"id":1,"doub_id":100,"title":"早春晴朗","ejs":"全集","episodes":"24","tp":2,"seed_num":128}
    ]}}
    """
    let videos = try ButaiParser.parseMovieList(Data(json.utf8), kind: .tvSeries)
    #expect(videos[0].currentEpisode == 24)
    #expect(videos[0].episodeCount == 24)
  }

  /// 接口失败外壳必须抛错而非静默空数组
  @Test func failureResponseThrows() {
    let json = """
    {"success":false,"code":10101,"message":"接口鉴权失败"}
    """
    #expect(throws: ButaiParseError.self) {
      _ = try ButaiParser.parseMovieList(Data(json.utf8), kind: .tvSeries)
    }
  }

  /// 字段缺失容错：空对象也不崩
  @Test func malformedRowDoesNotCrash() throws {
    let json = """
    {"success":true,"code":200,"data":{"list":[{}]}}
    """
    let videos = try ButaiParser.parseMovieList(Data(json.utf8), kind: .tvSeries)
    #expect(videos.count == 1)
    #expect(videos[0].title == "")
  }
}