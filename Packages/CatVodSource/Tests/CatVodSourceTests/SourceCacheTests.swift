import CatVodCore
import Foundation
import Testing

@testable import CatVodSource

// 测试辅助（同 target 内共享：见 SourceCacheCleanupTests.swift）

func makeCacheTempDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("yplayer-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// 写一个指定大小与修改时间的假缓存文件（用于验证淘汰顺序）。
func writeCacheFile(_ name: String, bytes: Int, in directory: URL, modified: Date?) throws {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    if let modified {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

// 不用强解包（SwiftLint `force_unwrapping`）：字面量必然合法，回退值不会真的用到。
let cacheTestJSURL = URL(string: "https://example.com/ceshi/index.js") ?? URL(fileURLWithPath: "/")
let cacheTestJSONURL = URL(string: "https://example.com/config.json") ?? URL(fileURLWithPath: "/")

@Suite("接口缓存管理（读取）")
struct SourceCacheTests {
    @Test("列出条目并标记当前接口")
    func entriesMarkCurrent() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory)

        // 当前接口是 JS 源：应有 bundle 与 .md5 两个文件
        let current = SourceCacheStore.cacheFileNames(for: cacheTestJSURL)
        #expect(current.count == 2)
        for name in current {
            try writeCacheFile(name, bytes: 16, in: directory, modified: nil)
        }
        try writeCacheFile("config-deadbeef.js", bytes: 32, in: directory, modified: nil)

        let entries = try store.entries(currentURL: cacheTestJSURL)
        #expect(entries.count == 3)
        #expect(entries.filter(\.isCurrent).count == 2)
        #expect(entries.first { $0.fileName.hasSuffix(".md5") }?.isDigest == true)
    }

    @Test("概览统计总占用与可清理的残留")
    func summaryCounts() throws {
        let directory = try makeCacheTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceCacheStore(directory: directory)

        let currentName = SourceCacheStore.cacheFileNames(for: cacheTestJSONURL).first ?? "current.json"
        try writeCacheFile(currentName, bytes: 100, in: directory, modified: nil)
        try writeCacheFile("config-old1.js", bytes: 200, in: directory, modified: nil)
        try writeCacheFile("config-old2.js", bytes: 300, in: directory, modified: nil)

        let summary = try store.summary(currentURL: cacheTestJSONURL)
        #expect(summary.entryCount == 3)
        #expect(summary.totalByteCount == 600)
        #expect(summary.currentEntryCount == 1)
        #expect(summary.orphanByteCount == 500)
        #expect(summary.latestModifiedAt != nil)
        #expect(!summary.formattedTotalSize.isEmpty)
    }

    @Test("缓存文件名只有一处来源（与 ConfigLocator 一致）")
    func namesComeFromLocator() throws {
        let located = try #require(ConfigLocator.locate(cacheTestJSURL.absoluteString))
        #expect(
            SourceCacheStore.cacheFileNames(for: cacheTestJSURL)
                == [located.cacheFileName, located.cacheFileName + ConfigLocator.digestSuffix]
        )
        #expect(SourceCacheStore.cacheFileNames(for: nil).isEmpty)
    }
}
