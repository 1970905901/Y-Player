import CatVodCore
@testable import CatVodSource
import Foundation
import Testing

// 清理与淘汰（辅助函数见 SourceCacheTests.swift）

@Suite("接口缓存管理（清理与淘汰）")
struct SourceCacheCleanupTests {
    @Test("清空全部缓存")
    func clearAll() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory)
        try writeCacheFile("config-a.js", bytes: 10, in: directory, modified: nil)
        try writeCacheFile("config-b.json", bytes: 10, in: directory, modified: nil)

        let removed = try store.clear()
        #expect(removed == 2)
        let remaining = try store.entries()
        #expect(remaining.isEmpty)
    }

    @Test("清残留：只保留当前接口")
    func pruneOrphans() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory)
        for name in SourceCacheStore.cacheFileNames(for: cacheTestJSURL) {
            try writeCacheFile(name, bytes: 10, in: directory, modified: nil)
        }
        try writeCacheFile("config-gone.js", bytes: 10, in: directory, modified: nil)

        let removed = try store.pruneOrphans(currentURL: cacheTestJSURL)
        let remaining = try store.entries(currentURL: cacheTestJSURL)
        // `allSatisfy` 是 rethrows：不能在 `#expect` 宏里直接调用（见 SourceCacheTests 的说明）。
        let allCurrent = remaining.allSatisfy(\.isCurrent)

        #expect(removed == 1)
        #expect(remaining.count == 2)
        #expect(allCurrent)
    }

    @Test("容量上限：最旧的先淘汰，且不动当前接口")
    func enforceLimit() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory, maxByteCount: 100)
        let now = Date()

        // 当前接口（JSON）60 字节 + 两个旧 JS 缓存各 60 字节 → 共 180 > 100
        let currentName = SourceCacheStore.cacheFileNames(for: cacheTestJSONURL).first ?? "current.json"
        try writeCacheFile(currentName, bytes: 60, in: directory, modified: now)
        try writeCacheFile("config-oldest.js", bytes: 60, in: directory, modified: now.addingTimeInterval(-300))
        try writeCacheFile("config-newer.js", bytes: 60, in: directory, modified: now.addingTimeInterval(-60))

        let removed = try store.enforceLimit(currentURL: cacheTestJSONURL)
        let remaining = try store.entries(currentURL: cacheTestJSONURL)
        // `contains(where:)` 同样是 rethrows，取出宏外再断言。
        let keepsCurrent = remaining.contains { $0.fileName == currentName }
        let droppedOldest = remaining.contains { $0.fileName == "config-oldest.js" }

        #expect(removed == 1)
        #expect(remaining.count == 2)
        #expect(keepsCurrent)
        #expect(!droppedOldest)
    }

    @Test("容量上限：只剩当前接口时停止淘汰（不会删掉正在用的缓存）")
    func enforceLimitKeepsCurrent() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory, maxByteCount: 10)
        let currentName = SourceCacheStore.cacheFileNames(for: cacheTestJSONURL).first ?? "current.json"
        try writeCacheFile(currentName, bytes: 500, in: directory, modified: nil)

        let removed = try store.enforceLimit(currentURL: cacheTestJSONURL)
        #expect(removed == 0)
        let remaining = try store.entries(currentURL: cacheTestJSONURL)
        #expect(remaining.count == 1)
    }

    @Test("目录不存在时全部接口都安全返回空")
    func missingDirectoryIsSafe() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yplayer-missing-\(UUID().uuidString)", isDirectory: true)
        let store = SourceCacheStore(directory: directory)

        // 注意：`try` 不能写在 `#expect(...)` 宏参数里（Swift Testing 限制，与 `await` 同类），
        // 必须先把结果取到局部变量再断言。
        let entries = try store.entries()
        let summary = try store.summary()
        let cleared = try store.clear()
        let pruned = try store.pruneOrphans(currentURL: cacheTestJSURL)
        let enforced = try store.enforceLimit(currentURL: cacheTestJSURL)

        #expect(entries.isEmpty)
        #expect(summary.entryCount == 0)
        #expect(cleared == 0)
        #expect(pruned == 0)
        #expect(enforced == 0)
    }
}
