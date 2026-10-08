import CatVodCore
import Foundation
import Testing

@Suite("直播收藏与「收藏」分组（M07c-5）")
struct LiveFavoritesTests {
    /// 一份够用的清单：央视两条频道（第一条两条线路）、卫视一条、一个加密分组。
    private func makeSource() throws -> LiveSource {
        let json = """
        {"name":"演示直播","groups":[
          {"name":"央视","channel":[
            {"name":"CCTV-1","urls":["http://a/1.m3u8$线路一","http://a/2.m3u8"]},
            {"name":"CCTV-2","urls":["http://a/3.m3u8"]}
          ]},
          {"name":"卫视","channel":[{"name":"湖南卫视","urls":["http://b/1.m3u8"]}]},
          {"name":"加密_1234","channel":[{"name":"加密台","urls":["http://c/1.m3u8"]}]}
        ]}
        """
        return try JSONDecoder().decode(LiveSource.self, from: Data(json.utf8))
    }

    @Test("收藏分组名与判定：用名字认（上游 `Group.isKeep()` / 资源字符串）")
    func keepGroupName() {
        #expect(LiveGroup.keepName == "收藏")
        #expect(LiveGroup(name: "收藏").isKeep)
        #expect(!LiveGroup(name: "央视").isKeep)
    }

    @Test("切换收藏：已收藏就删，未收藏插到最前；同名不会重复，空名字忽略")
    func toggling() {
        let first = LiveFavorite(name: "CCTV-1")
        let second = LiveFavorite(name: "湖南卫视")

        let two = LiveFavorites.toggling(second, in: LiveFavorites.toggling(first, in: []))
        #expect(two.map(\.name) == ["湖南卫视", "CCTV-1"])
        #expect(LiveFavorites.contains("CCTV-1", in: two))

        // 再点一次 = 取消收藏。
        #expect(LiveFavorites.toggling(first, in: two).map(\.name) == ["湖南卫视"])

        // 重复收藏已在列表里的频道：不插第二条，也不改顺序。
        let duplicated = LiveFavorites.toggling(first, in: two)
        #expect(duplicated.count == 1)
        #expect(LiveFavorites.toggling(LiveFavorite(name: ""), in: two) == two)
    }

    @Test("收藏分组：按**清单顺序**收集命中频道，用的是清单里的频道（不是收藏时的快照）")
    func buildsGroup() throws {
        let source = try makeSource()
        // 收藏顺序与清单顺序故意相反。
        let favorites = [LiveFavorite(name: "湖南卫视"), LiveFavorite(name: "CCTV-1")]

        let group = try #require(LiveFavorites.group(in: source, favorites: favorites))
        #expect(group.name == LiveGroup.keepName)
        #expect(group.channels.map(\.name) == ["CCTV-1", "湖南卫视"])
        // 地址 / 线路跟着清单走（收藏只存名字）。
        #expect(group.channels[0].urls.count == 2)
        #expect(group.channels[1].urls == ["http://b/1.m3u8"])
    }

    @Test("收藏分组：没用收藏、或收藏的频道已不在清单里，就不给这一组")
    func emptyGroup() throws {
        let source = try makeSource()
        #expect(LiveFavorites.group(in: source, favorites: []) == nil)
        #expect(LiveFavorites.group(in: source, favorites: [LiveFavorite(name: "已下架的频道")]) == nil)
    }

    @Test("按名字定位频道：返回它**真正**所在的分组，线路下标越界收敛")
    func locatesRealGroup() throws {
        let source = try makeSource()
        let target = try #require(LiveKeep.locate(channelNamed: "CCTV-1", in: source, line: 1))
        #expect(target.group.name == "央视")
        #expect(target.lineIndex == 1)

        #expect(LiveKeep.locate(channelNamed: "CCTV-1", in: source, line: 9)?.lineIndex == 0)

        // 加密分组里的频道也定位得到（能不能收藏 / 记 keep 由调用方按 `isHidden` 判，见 `AppModel+Live`）。
        let hidden = try #require(LiveKeep.locate(channelNamed: "加密台", in: source))
        #expect(hidden.group.isHidden)

        #expect(LiveKeep.locate(channelNamed: "不存在的频道", in: source) == nil)
    }
}
