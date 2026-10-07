import CatVodCore
@testable import CatVodStore
import Foundation
import Testing

@Suite("GRDB 落库：收藏与播放进度")
struct GRDBStoreTests {
    private func makeDatabase() throws -> GRDBDatabase {
        try GRDBDatabase()
    }

    private func key(_ vodID: String, site: String = "cms") -> PlaybackKey {
        PlaybackKey(siteKey: site, vodID: vodID)
    }

    @Test("收藏：写入 / 读取 / 计数 / 按时间倒序")
    func favoriteRoundTrip() async throws {
        let database = try makeDatabase()
        let store = GRDBFavoriteStore(database: database)
        let older = Favorite(
            key: key("1"),
            vodName: "老片",
            picture: "https://img/1.jpg",
            siteName: "站点A",
            lineName: "线路1",
            episodeName: "第1集",
            addedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = Favorite(
            key: key("2"),
            vodName: "新片",
            addedAt: Date(timeIntervalSince1970: 2000)
        )
        await store.add(older)
        await store.add(newer)

        let count = await store.count()
        #expect(count == 2)

        let all = await store.favorites()
        #expect(all.map(\.key.vodID) == ["2", "1"])

        let loaded = await store.favorite(for: key("1"))
        #expect(loaded?.vodName == "老片")
        #expect(loaded?.picture == "https://img/1.jpg")
        #expect(loaded?.lineName == "线路1")
        #expect(loaded?.addedAt == Date(timeIntervalSince1970: 1000))

        // 同名键重复收藏：覆盖而不是新增。
        await store.add(Favorite(key: key("1"), vodName: "老片（改名）", addedAt: Date(timeIntervalSince1970: 3000)))
        let replaced = await store.count()
        #expect(replaced == 2)
        let renamed = await store.favorite(for: key("1"))
        #expect(renamed?.vodName == "老片（改名）")
    }

    @Test("收藏：单条删除与批量删除")
    func favoriteDeletion() async throws {
        let database = try makeDatabase()
        let store = GRDBFavoriteStore(database: database)
        for index in 1 ... 3 {
            await store.add(Favorite(key: key("\(index)"), vodName: "片\(index)"))
        }
        await store.remove(for: key("1"))
        let afterSingle = await store.count()
        #expect(afterSingle == 2)
        let removed = await store.favorite(for: key("1"))
        #expect(removed == nil)

        await store.removeAll(for: [key("2"), key("3")])
        let afterBatch = await store.count()
        #expect(afterBatch == 0)
        let empty = await store.favorites()
        #expect(empty.isEmpty)

        // 空数组不应触发写库（也不该报错）。
        await store.removeAll(for: [])
        let failures = await store.failureMessages
        #expect(failures.isEmpty)
    }

    @Test("进度：写入 / 读取（含元数据 JSON 往返）/ 清除 / 排序")
    func progressRoundTrip() async throws {
        let database = try makeDatabase()
        let store = GRDBPlaybackProgressStore(database: database)
        let metadata = PlaybackEntryMetadata(
            vodName: "片名",
            picture: "https://img/x.jpg",
            siteName: "站点A",
            lineName: "线路2",
            episodeName: "第9集"
        )
        await store.save(
            PlaybackProgress(
                key: key("9"),
                position: 120,
                duration: 600,
                isFinished: false,
                episodeIndex: 8,
                updatedAt: Date(timeIntervalSince1970: 5000),
                metadata: metadata
            )
        )
        await store.save(
            PlaybackProgress(
                key: key("10"),
                position: 5,
                duration: 100,
                isFinished: true,
                episodeIndex: 1,
                updatedAt: Date(timeIntervalSince1970: 9000)
            )
        )

        let loaded = await store.progress(for: key("9"))
        let record = try #require(loaded)
        #expect(record.position == 120)
        #expect(record.duration == 600)
        #expect(record.episodeIndex == 8)
        #expect(record.metadata == metadata)
        #expect(record.resumePosition() == 120)
        #expect(record.displayName == "片名")

        let finishedRecord = await store.progress(for: key("10"))
        let finished = try #require(finishedRecord)
        #expect(finished.isFinished)
        // 看完的条目不续播。
        #expect(finished.resumePosition() == 0)

        let all = await store.all()
        #expect(all.map(\.key.vodID) == ["10", "9"])

        await store.clear(for: key("9"))
        let remaining = await store.count()
        #expect(remaining == 1)
        let cleared = await store.progress(for: key("9"))
        #expect(cleared == nil)
    }

    @Test("落盘：关闭后用同一路径重开，数据仍在（对照「杀进程即丢」）")
    func persistenceAcrossReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-test-\(UUID().uuidString).sqlite")
            .path
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        let first = try GRDBDatabase(path: path)
        let favoriteStore = GRDBFavoriteStore(database: first)
        let progressStore = GRDBPlaybackProgressStore(database: first)
        await favoriteStore.add(Favorite(key: key("42"), vodName: "跨进程留存"))
        await progressStore.save(PlaybackProgress(key: key("42"), position: 88, duration: 300, episodeIndex: 2))

        // 重新打开同一个文件（等价于应用重启）。
        let second = try GRDBDatabase(path: path)
        let reopenedFavorites = GRDBFavoriteStore(database: second)
        let reopenedProgress = GRDBPlaybackProgressStore(database: second)

        let favorite = await reopenedFavorites.favorite(for: key("42"))
        #expect(favorite?.vodName == "跨进程留存")
        let progress = await reopenedProgress.progress(for: key("42"))
        #expect(progress?.position == 88)
        #expect(progress?.episodeIndex == 2)

        let failures = await reopenedProgress.failureMessages
        let favoriteFailures = await reopenedFavorites.failureMessages
        #expect(failures.isEmpty)
        #expect(favoriteFailures.isEmpty)
    }
}
