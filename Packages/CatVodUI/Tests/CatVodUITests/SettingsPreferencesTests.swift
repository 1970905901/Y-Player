import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("设置偏好：缓存有效期 / 弹幕 API / 播放页")
struct SettingsPreferencesTests {
    // MARK: - CacheLifetime

    @Test("缓存有效期的展示名与时长为参考图的取值")
    func cacheLifetimeValues() {
        #expect(CacheLifetime.hours12.displayName == "12小时")
        #expect(CacheLifetime.days7.displayName == "7天")
        // 显式写成 `TimeInterval`：Swift Testing 的 `#expect` 在两侧类型不同（`Double?` vs `Int`）
        // 时是按**字符串**比较的，`43200.0` 与 `43200` 会被判成不相等 —— 这里踩过一次。
        #expect(CacheLifetime.hours12.timeInterval == TimeInterval(12 * 60 * 60))
        #expect(CacheLifetime.days7.timeInterval == TimeInterval(7 * 24 * 60 * 60))
        #expect(CacheLifetime.never.timeInterval == nil)
        #expect(CacheLifetime.allCases.count == 5)
    }

    @Test("有效期判定：读不到时间按过期处理，「永不」始终新鲜")
    func cacheLifetimeFreshness() {
        let now = Date()
        #expect(!CacheLifetime.hours12.isFresh(writtenAt: nil, now: now))
        #expect(CacheLifetime.never.isFresh(writtenAt: Date(timeIntervalSince1970: 0), now: now))
        #expect(CacheLifetime.hours12.isFresh(writtenAt: now.addingTimeInterval(-11 * 60 * 60), now: now))
        #expect(!CacheLifetime.hours12.isFresh(writtenAt: now.addingTimeInterval(-13 * 60 * 60), now: now))
    }

    // MARK: - DanmakuAPIConfig

    @Test("地址槽位恒为 4 个：不足补齐、超出截断")
    func danmakuSlotNormalization() {
        #expect(DanmakuAPIConfig().addresses.count == DanmakuAPIConfig.slotCount)
        #expect(DanmakuAPIConfig(addresses: ["a"]).addresses == ["a", "", "", ""])
        #expect(DanmakuAPIConfig(addresses: ["a", "b", "c", "d", "e"]).addresses.count == 4)
    }

    @Test("越界读写不崩：读空串、写忽略")
    func danmakuOutOfRange() {
        var config = DanmakuAPIConfig(addresses: ["a"])
        #expect(config.address(at: 9) == "")
        config.setAddress("x", at: 9)
        #expect(config.addresses == ["a", "", "", ""])
        config.setAddress("x", at: 2)
        #expect(config.address(at: 2) == "x")
    }

    @Test("持久化往返：开关与四个地址都能还原")
    func danmakuPersistenceRoundTrip() {
        var config = DanmakuAPIConfig(isEnabled: true, addresses: ["https://a", "", "https://c", ""])
        config.setAddress("https://d", at: 3)
        #expect(DanmakuAPIConfig.decode(config.persistenceValue) == config)
        #expect(DanmakuAPIConfig.decode(nil) == DanmakuAPIConfig())
        #expect(DanmakuAPIConfig.decode("") == DanmakuAPIConfig())
    }

    @Test("已填地址统计忽略空白项")
    func danmakuFilledCount() {
        let config = DanmakuAPIConfig(addresses: ["https://a", "   ", "https://c", ""])
        #expect(config.filledAddresses.count == 2)
    }

    // MARK: - PlaybackPageLayout

    @Test("播放页两种视图都有展示名与说明")
    func playbackPageLayouts() {
        #expect(PlaybackPageLayout.compact.displayName == "精简视图")
        #expect(PlaybackPageLayout.emby.displayName == "Emby 视图")
        #expect(PlaybackPageLayout.allCases.count == 2)
        #expect(!PlaybackPageLayout.emby.summary.isEmpty)
    }
}

@Suite("首页缓存：键与读写")
struct HomeCacheStoreTests {
    private func makeStore() -> (HomeCacheStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yplayer-home-cache-\(UUID().uuidString)", isDirectory: true)
        return (HomeCacheStore(directory: directory), directory)
    }

    @Test("筛选顺序不影响缓存键（同一筛选组合只对应一个文件）")
    func keyIgnoresFilterOrder() {
        let first = HomeCacheStore.Key(siteKey: "s", categoryID: "1", page: 2, extend: ["a": "1", "b": "2"])
        let second = HomeCacheStore.Key(siteKey: "s", categoryID: "1", page: 2, extend: ["b": "2", "a": "1"])
        #expect(first.fileName == second.fileName)
    }

    @Test("站点 / 分类 / 页不同则键不同")
    func keyVariesByScope() {
        let base = HomeCacheStore.Key(siteKey: "s", categoryID: "1", page: 1)
        let otherSite = HomeCacheStore.Key(siteKey: "t", categoryID: "1", page: 1)
        let otherPage = HomeCacheStore.Key(siteKey: "s", categoryID: "1", page: 2)
        let otherCategory = HomeCacheStore.Key(siteKey: "s", categoryID: "2", page: 1)
        #expect(base.fileName != otherSite.fileName)
        #expect(base.fileName != otherPage.fileName)
        #expect(base.fileName != otherCategory.fileName)
        #expect(base.fileName.hasPrefix("home-"))
    }

    @Test("写进去能读出来；过期或清空之后读不到")
    func writeReadClear() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = HomeCacheStore.Key(siteKey: "s", categoryID: "1", page: 1)
        let result = SpiderResult()
        store.write(result, key: key)

        // 写进去再读出来应与原值相同（JSON 往返保真）。
        #expect(store.read(key, maxAge: 60) == result)
        // maxAge 传 0：任何写入时间都算过期（走「过期即未命中」这条分支）。
        #expect(store.read(key, maxAge: 0) == nil)

        let summary = try store.summary()
        #expect(summary.entryCount == 1)
        #expect(summary.byteCount > 0)
        #expect(!summary.formattedSize.isEmpty)

        #expect(try store.clear() == 1)
        #expect(store.read(key, maxAge: 60) == nil)
    }

    @Test("目录不存在时概览为零、清理不报错")
    func emptyDirectory() throws {
        let (store, directory) = makeStore()
        #expect(try store.summary().entryCount == 0)
        #expect(try store.clear() == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Suite("存储空间：格式化与目录占用")
struct StorageSpaceTests {
    @Test("目录占用：nil 或目录不存在都算 0")
    func directoryByteCount() {
        #expect(StorageSpace.directoryByteCount(nil) == 0)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yplayer-missing-\(UUID().uuidString)")
        #expect(StorageSpace.directoryByteCount(missing) == 0)
    }

    @Test("快照的占比取值合法、格式化文本非空")
    func snapshotShape() {
        let snapshot = StorageSpace.snapshot(downloadDirectory: nil)
        #expect(snapshot.usedRatio >= 0)
        #expect(snapshot.usedRatio <= 1)
        #expect(snapshot.totalBytes >= 0)
        #expect(!StorageSpace.format(0).isEmpty)
        #expect(!snapshot.formattedDownload.isEmpty)
    }
}
