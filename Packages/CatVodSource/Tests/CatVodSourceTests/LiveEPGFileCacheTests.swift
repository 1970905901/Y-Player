import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 文件形态节目单的落盘缓存（M07d7）：键稳定、往返无损、清空与概览都对。
@Suite("EPG 文件缓存：存取")
struct LiveEPGFileCacheTests {
    private func makeDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yplayer-epg-cache-tests")
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("文件名：同一个地址永远同一个文件，不同地址不撞")
    func stableFileName() throws {
        let cache = LiveEPGFileCache(directory: try makeDirectory("names"))
        let first = cache.fileName(for: "https://live.example.com/epg/cctv.xml")
        #expect(first == cache.fileName(for: "https://live.example.com/epg/cctv.xml"))
        #expect(first != cache.fileName(for: "https://live.example.com/epg/other.xml"))
        #expect(first.hasPrefix("epg-"))
        #expect(first.hasSuffix(".bin"))
    }

    @Test("写→读：原样字节 + 落盘时间；没写过的地址读回 nil")
    func roundTrip() throws {
        let cache = LiveEPGFileCache(directory: try makeDirectory("roundtrip"))
        let url = "https://live.example.com/epg/cctv.xml.gz"
        #expect(cache.read(url) == nil)

        // 存的是「服务器原样给的字节」：这里故意给 gz 魔数开头，读回来必须一个字节不差。
        let bytes = Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02])
        cache.store(bytes, for: url)
        let entry = try #require(cache.read(url))
        #expect(entry.data == bytes)
        #expect(abs(entry.modifiedAt.timeIntervalSinceNow) < 60)
    }

    @Test("概览与清空：条数 / 占用 / 最近写入都在，清空返回删了几个")
    func summaryAndClear() throws {
        let cache = LiveEPGFileCache(directory: try makeDirectory("summary"))
        cache.store(Data(repeating: 0x41, count: 100), for: "https://a.example.com/1.xml")
        cache.store(Data(repeating: 0x42, count: 50), for: "https://a.example.com/2.xml")

        let summary = cache.summary()
        #expect(summary.entryCount == 2)
        #expect(summary.byteCount == 150)
        #expect(summary.latestModifiedAt != nil)

        #expect(cache.clear() == 2)
        #expect(cache.summary().entryCount == 0)
        #expect(cache.read("https://a.example.com/1.xml") == nil)
    }
}
