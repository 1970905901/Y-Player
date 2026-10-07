import CatVodCore
import CatVodStore
@testable import CatVodUI
import Foundation
import Testing

@Suite("本地存储接线（M08b）")
struct StorageWiringTests {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-wiring-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("test.sqlite")
    }

    @Test("能打开临时路径的库、真的落盘，并且重复打开仍然成功（迁移幂等）")
    @MainActor
    func opensAndMigrates() throws {
        let url = temporaryDatabaseURL()
        defer {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let first = try #require(AppModel.openStorageDatabase(at: url))
        #expect(first.path == url.path)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // 再次打开同一文件：迁移必须幂等（否则第二次启动就崩）。
        let second = try #require(AppModel.openStorageDatabase(at: url))
        #expect(second.path == url.path)
        #expect(second.failures.recent.isEmpty)
    }

    @Test("路径不可用时返回 nil（调用方据此退回内存实现）")
    @MainActor
    func reportsUnusablePath() {
        // 用一个「父路径是文件」的地址：`createDirectory` 必然失败，进而打不开库。
        let blocked = URL(fileURLWithPath: "/dev/null/yplayer/test.sqlite")
        #expect(AppModel.openStorageDatabase(at: blocked) == nil)
    }

    @Test("默认库路径在 Application Support 下的 YPlayer 目录里")
    @MainActor
    func defaultDatabasePath() {
        let url = AppModel.storageDatabaseURL()
        #expect(url.lastPathComponent == "YPlayer.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "YPlayer")
    }
}
