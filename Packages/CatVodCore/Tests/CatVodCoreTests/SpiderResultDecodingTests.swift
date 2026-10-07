import CatVodCore
import Foundation
import Testing

@Suite("Result / Vod 解码")
struct SpiderResultDecodingTests {
    @Test("分类、别名与筛选")
    func categoriesAndFilters() throws {
        let result = try JSONDecoder().decode(SpiderResult.self, from: fixtureData("spider-result"))

        #expect(result.categories.count == 2)
        #expect(result.categories[0].typeID == "movie")
        #expect(result.categories[0].typeName == "电影")
        // 别名 id/name
        #expect(result.categories[1].typeID == "tv")
        #expect(result.categories[1].typeName == "剧集")
        #expect(result.categories[1].typeFlag == "1")

        let filters = try #require(result.filters["movie"])
        #expect(filters.count == 1)
        #expect(filters[0].key == "area")
        #expect(filters[0].initialValue == "大陆")
        #expect(filters[0].values.count == 2)
        #expect(filters[0].initialIndex == 0)
        #expect(filters[0].values[1].name == "香港")
    }

    @Test("列表条目样式与分页字段")
    func listAndPaging() throws {
        let result = try JSONDecoder().decode(SpiderResult.self, from: fixtureData("spider-result"))
        #expect(result.hasList)
        #expect(result.page == 2)
        #expect(result.pagecount == 5)
        #expect(result.total == 100)

        let first = result.list[0]
        #expect(first.vodRemarks == "全 2 集")
        #expect(first.land == 1)
        #expect(first.ratio == 1.33)
        #expect(!first.isFolder)

        #expect(result.list[1].isFolder)
    }

    @Test("播放列表：$$$ 线路与 # 选集")
    func playlistFromVod() throws {
        let result = try JSONDecoder().decode(SpiderResult.self, from: fixtureData("spider-result"))
        let item = result.list[0]
        let lines = PlaylistParser.parse(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL)

        #expect(lines.count == 2)
        #expect(lines[0].name == "主线")
        #expect(lines[0].episodes.map(\.name) == ["第1集", "第2集"])
        #expect(lines[0].episodes.map(\.url) == ["id-1", "id-2"])
        #expect(lines[1].name == "备用线")
        #expect(lines[1].episodes.count == 1)
        #expect(PlaylistParser.consistencyIssues(playFrom: item.vodPlayFrom, playURL: item.vodPlayURL).isEmpty)
    }

    @Test("播放结果：多地址、header、字幕弹幕与 DRM 能力")
    func playResult() throws {
        let result = try JSONDecoder().decode(SpiderResult.self, from: fixtureData("spider-play"))

        #expect(result.requiresParsing)
        #expect(result.url.entries.count == 2)
        #expect(result.url.selectedIndex == 1)
        #expect(result.url.selected?.name == "标清")
        #expect(result.url.selected?.url == "https://example.com/sd.m3u8")

        #expect(result.header["Referer"] == "https://example.com/")
        #expect(result.format == "application/x-mpegURL")
        #expect(result.subs.count == 1)
        #expect(result.danmaku.count == 1)
        #expect(result.position == 128_000)
        #expect(result.flag == "主线")
        #expect(result.jxFrom == "演示解析")

        let drm = try #require(result.drm)
        #expect(drm.scheme == .widevine)
        // Apple 平台不支持 Widevine，必须能给出原因而不是“默默失败”
        #expect(!drm.availability.isAvailable)
        #expect(drm.availability.reason?.contains("widevine") == true)
    }

    @Test("直链字符串形态与空结果")
    func directAndEmpty() throws {
        let direct = try JSONDecoder().decode(SpiderResult.self, from: Data(#"{"url":"https://a/b.mp4"}"#.utf8))
        #expect(direct.url.entries.count == 1)
        #expect(direct.primaryPlaybackURL == "https://a/b.mp4")
        #expect(!direct.requiresParsing)

        let empty = SpiderResult.empty(page: 3)
        #expect(empty.page == 3)
        #expect(empty.pagecount == 0)
        #expect(!empty.hasList)
    }

    @Test("数组形态 url 成对解析，奇数项按单地址处理")
    func arrayURL() throws {
        let data = Data(#"{"url":["标清","https://a/sd.m3u8","高清","https://a/hd.m3u8","https://a/orphan.m3u8"]}"#.utf8)
        let result = try JSONDecoder().decode(SpiderResult.self, from: data)
        #expect(result.url.entries.count == 3)
        #expect(result.url.entries[2].name.isEmpty)
        #expect(result.url.entries[2].url == "https://a/orphan.m3u8")
    }
}
