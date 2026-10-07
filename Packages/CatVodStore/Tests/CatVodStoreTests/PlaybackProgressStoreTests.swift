import CatVodCore
@testable import CatVodStore
import Foundation
import Testing

@Suite("播放进度（接口预留 + 内存实现）")
struct PlaybackProgressStoreTests {
    private func key(_ siteKey: String = "cat", _ vodID: String = "1") -> PlaybackKey {
        PlaybackKey(siteKey: siteKey, vodID: vodID)
    }

    @Test("续播位置：已看完 / 过短 / 正常 三种情况")
    func resumePosition() {
        let normal = PlaybackProgress(key: key(), position: 120, duration: 3600)
        #expect(normal.resumePosition() == 120)

        let tooShort = PlaybackProgress(key: key(), position: 3, duration: 3600)
        #expect(tooShort.resumePosition() == 0)

        let finished = PlaybackProgress(key: key(), position: 3000, duration: 3600, isFinished: true)
        #expect(finished.resumePosition() == 0)
    }

    @Test("进度比例与「接近看完」判定")
    func fraction() {
        let half = PlaybackProgress(key: key(), position: 50, duration: 100)
        #expect(half.fraction == 0.5)
        #expect(!half.isEffectivelyFinished)

        let almost = PlaybackProgress(key: key(), position: 96, duration: 100)
        #expect(almost.isEffectivelyFinished)

        let unknownDuration = PlaybackProgress(key: key(), position: 96, duration: 0)
        #expect(unknownDuration.fraction == 0)
        #expect(!unknownDuration.isEffectivelyFinished)
    }

    @Test("内存实现：保存 / 读取 / 清空")
    func memoryStoreBasics() async {
        let store = InMemoryPlaybackProgressStore()
        let target = key("cat", "100")
        await store.save(PlaybackProgress(key: target, position: 42, duration: 100, episodeIndex: 3))

        let loaded = await store.progress(for: target)
        #expect(loaded?.position == 42)
        #expect(loaded?.duration == 100)
        #expect(loaded?.episodeIndex == 3)

        let missing = await store.progress(for: key("cat", "999"))
        #expect(missing == nil)

        await store.clear(for: target)
        let cleared = await store.progress(for: target)
        #expect(cleared == nil)
    }

    @Test("all() 按更新时间倒序，不同站点的同一个 vodID 互不覆盖")
    func storeKeysAndOrdering() async {
        let store = InMemoryPlaybackProgressStore()
        let older = Date().addingTimeInterval(-600)
        await store.save(PlaybackProgress(key: key("a", "1"), position: 10, duration: 100, updatedAt: older))
        await store.save(PlaybackProgress(key: key("b", "1"), position: 20, duration: 100))

        let records = await store.all()
        #expect(records.count == 2)
        #expect(records.first?.key.siteKey == "b")
        #expect(records.last?.key.siteKey == "a")

        let count = await store.count()
        #expect(count == 2)
    }

    @Test("PlaybackKey 的持久化键稳定（站点 + vodID）")
    func storageKeyShape() {
        #expect(key("cat", "100").storageKey == "cat#100")
    }
}
