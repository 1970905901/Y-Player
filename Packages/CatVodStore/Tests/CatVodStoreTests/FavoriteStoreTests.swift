import CatVodCore
@testable import CatVodStore
import Foundation
import Testing

@Suite("收藏（接口预留 + 内存实现）")
struct FavoriteStoreTests {
    private func key(_ siteKey: String = "cat", _ vodID: String = "1") -> PlaybackKey {
        PlaybackKey(siteKey: siteKey, vodID: vodID)
    }

    @Test("用播放元数据构造收藏：片名/封面/站源/线路/集名全部带过去")
    func initFromMetadata() {
        let metadata = PlaybackEntryMetadata(
            vodName: "完美世界",
            picture: "https://img/cover.jpg",
            siteName: "「盘」木偶",
            lineName: "UC 无限",
            episodeName: "02 [2.11GB]"
        )
        let favorite = Favorite(key: key(), metadata: metadata, addedAt: Date(timeIntervalSince1970: 100))
        #expect(favorite.vodName == "完美世界")
        #expect(favorite.picture == "https://img/cover.jpg")
        #expect(favorite.siteName == "「盘」木偶")
        #expect(favorite.lineName == "UC 无限")
        #expect(favorite.episodeName == "02 [2.11GB]")
        #expect(favorite.id == "cat#1")
    }

    @Test("内存实现：新增 / 查询 / 单条删除 / 批量删除")
    func memoryStoreBasics() async {
        let store = InMemoryFavoriteStore()
        let first = key("cat", "100")
        let second = key("cat", "200")
        await store.add(Favorite(key: first, vodName: "完美世界"))
        await store.add(Favorite(key: second, vodName: "斗罗大陆"))

        let saved = await store.favorite(for: first)
        #expect(saved?.vodName == "完美世界")
        let count = await store.count()
        #expect(count == 2)

        await store.remove(for: first)
        let removed = await store.favorite(for: first)
        #expect(removed == nil)

        await store.removeAll(for: [second])
        let remaining = await store.count()
        #expect(remaining == 0)
    }

    @Test("favorites() 按收藏时间倒序；同一视频 ID 在不同站点互不覆盖")
    func orderingAndIsolation() async {
        let store = InMemoryFavoriteStore()
        let older = Date().addingTimeInterval(-600)
        await store.add(Favorite(key: key("a", "1"), vodName: "A", addedAt: older))
        await store.add(Favorite(key: key("b", "1"), vodName: "B"))

        let list = await store.favorites()
        #expect(list.count == 2)
        #expect(list.first?.key.siteKey == "b")
        #expect(list.last?.key.siteKey == "a")
    }

    @Test("重复收藏同一个键：覆盖而不是新增一条")
    func addOverwrites() async {
        let store = InMemoryFavoriteStore()
        let target = key()
        await store.add(Favorite(key: target, vodName: "旧名"))
        await store.add(Favorite(key: target, vodName: "新名"))

        let count = await store.count()
        #expect(count == 1)
        let latest = await store.favorite(for: target)
        #expect(latest?.vodName == "新名")
    }
}
