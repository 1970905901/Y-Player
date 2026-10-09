import CatVodCore
@testable import CatVodStore
import Foundation
import Testing

@Suite("下载任务存储：内存实现")
struct InMemoryDownloadTaskStoreTests {
    private func task(
        _ episode: String,
        status: DownloadTask.Status = .waiting,
        offset: Double = 0
    ) -> DownloadTask {
        DownloadTask(
            siteKey: "wogg",
            title: "某剧",
            episode: episode,
            line: "线路一",
            url: "https://cdn.example/\(episode).m3u8",
            headers: ["User-Agent": "YPlayer", "Referer": "https://site.example"],
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    @Test("写入后按创建时间升序读出（队列顺序就是它）")
    func savesAndSortsByCreation() async {
        let store = InMemoryDownloadTaskStore()
        await store.save([task("第 2 集", offset: 1), task("第 1 集", offset: 0), task("第 3 集", offset: 2)])
        let all = await store.all()
        #expect(all.map(\.episode) == ["第 1 集", "第 2 集", "第 3 集"])
        #expect(await store.count() == 3)
    }

    @Test("同一条再写是覆盖：进度与状态一起更新，条数不变")
    func saveOverwrites() async {
        let store = InMemoryDownloadTaskStore()
        var item = task("第 1 集", status: .running)
        await store.save(item)

        item.receivedBytes = 500
        item.expectedBytes = 1000
        item.status = .finished
        await store.save(item)

        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.status == .finished)
        #expect(all.first?.progress == 0.5)
    }

    @Test("删一条与清空")
    func removesAndClears() async {
        let store = InMemoryDownloadTaskStore()
        let first = task("第 1 集", offset: 0)
        await store.save([first, task("第 2 集", offset: 1)])
        await store.remove(id: first.id)

        let remaining = await store.all()
        #expect(remaining.map(\.episode) == ["第 2 集"])

        await store.clear()
        #expect(await store.count() == 0)
    }
}

@Suite("下载任务存储：GRDB 实现")
struct GRDBDownloadTaskStoreTests {
    private func makeStore() throws -> GRDBDownloadTaskStore {
        // 内存库：迁移照跑（v2.download），但落在内存里 —— 与 `GRDBStoreTests` 同一套做法。
        try GRDBDownloadTaskStore(database: GRDBDatabase())
    }

    private func task(
        _ episode: String = "第 1 集",
        status: DownloadTask.Status = .waiting,
        received: Int64 = 0,
        expected: Int64 = 0
    ) -> DownloadTask {
        DownloadTask(
            siteKey: "wogg",
            title: "某剧",
            episode: episode,
            line: "线路一",
            url: "https://cdn.example/1.m3u8",
            headers: ["User-Agent": "YPlayer", "Referer": "https://site.example/剧集"],
            status: status,
            expectedBytes: expected,
            receivedBytes: received,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("往返：写一条读回来逐字段相等（含 header 里的中文）")
    func roundTrip() async throws {
        let store = try makeStore()
        let item = task(status: .running, received: 300, expected: 1000)
        await store.save(item)

        let loaded = await store.all()
        #expect(loaded.count == 1)
        #expect(loaded.first == item)
        #expect(loaded.first?.headers["Referer"] == "https://site.example/剧集")
    }

    @Test("恢复：库里的「下载中」读出来必须降级成「排队中」")
    func runningIsRecoveredAsWaiting() async throws {
        let store = try makeStore()
        await store.save(task(status: .running))

        let loaded = await store.all()
        #expect(loaded.first?.status == .waiting)
        // 其余状态原样保留
        await store.clear()
        await store.save(task(status: .paused))
        #expect(await store.all().first?.status == DownloadTask.Status.paused)
    }

    @Test("认不出来的状态字符串回落「排队中」：版本回退时不留一条永远不动的记录")
    func unknownStatusFallsBack() {
        #expect(GRDBDownloadTaskStore.recoveredStatus("paused") == .paused)
        #expect(GRDBDownloadTaskStore.recoveredStatus("running") == .waiting)
        #expect(GRDBDownloadTaskStore.recoveredStatus("未来才有的状态") == .waiting)
        #expect(GRDBDownloadTaskStore.recoveredStatus("") == .waiting)
    }

    @Test("同一条再写是覆盖（主键是派生出来的 id）")
    func saveOverwritesByID() async throws {
        let store = try makeStore()
        var item = task(status: .running)
        await store.save(item)
        item.receivedBytes = 800
        item.status = .finished
        await store.save(item)

        let loaded = await store.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.status == .finished)
        #expect(loaded.first?.receivedBytes == 800)
    }

    @Test("整批写：一次全进去，顺序按创建时间")
    func batchSave() async throws {
        let store = try makeStore()
        let tasks = (1 ... 5).map { index in
            DownloadTask(
                siteKey: "wogg",
                title: "某剧",
                episode: "第 \(index) 集",
                line: "线路一",
                url: "https://cdn.example/\(index).m3u8",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        let saved = await store.save(tasks)
        #expect(saved)
        let loaded = await store.all()
        #expect(loaded.map(\.episode) == ["第 1 集", "第 2 集", "第 3 集", "第 4 集", "第 5 集"])
        #expect(await store.count() == 5)
    }

    @Test("删一条 / 清空 / 空批写不算失败")
    func removesAndClears() async throws {
        let store = try makeStore()
        let first = task()
        let second = task("第 2 集")
        await store.save([first, second])
        await store.remove(id: first.id)
        #expect(await store.all().map(\.episode) == ["第 2 集"])

        await store.clear()
        #expect(await store.count() == 0)
        #expect(await store.save([]))
    }

    @Test("没写过任何东西时读出来是空、不报失败")
    func emptyStore() async throws {
        let store = try makeStore()
        #expect(await store.all().isEmpty)
        #expect(await store.count() == 0)
        #expect(store.failureMessages.isEmpty)
    }
}
