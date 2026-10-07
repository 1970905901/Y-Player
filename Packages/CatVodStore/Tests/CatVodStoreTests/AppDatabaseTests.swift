import CatVodCore
import Foundation
import Testing

@testable import CatVodStore

/// 内存实现：M1/M2 用于单测与预览，M2 之后与 GRDB 实现共存。
actor InMemoryAppDatabase: AppDatabase {
    private var siteList: [Site] = []
    private var positions: [String: Double] = [:]
    private var history: [String] = []

    func sites() async throws -> [Site] {
        siteList
    }

    func upsert(sites: [Site]) async throws {
        for site in sites {
            if let index = siteList.firstIndex(where: { $0.key == site.key }) {
                siteList[index] = site
            } else {
                siteList.append(site)
            }
        }
    }

    func playbackPosition(vodKey: String) async throws -> Double? {
        positions[vodKey]
    }

    func save(playbackPosition: Double, vodKey: String) async throws {
        positions[vodKey] = playbackPosition
    }

    func searchHistory() async throws -> [String] {
        history
    }

    func append(searchKeyword: String) async throws {
        guard !searchKeyword.isEmpty else {
            return
        }
        history.removeAll { $0 == searchKeyword }
        history.insert(searchKeyword, at: 0)
    }
}

@Suite("存储抽象")
struct AppDatabaseTests {
    @Test("站点 upsert 按 key 去重")
    func upsertSites() async throws {
        let database = InMemoryAppDatabase()
        try await database.upsert(sites: [
            Site(key: "a", name: "A", type: 1, api: "https://a.example.com"),
            Site(key: "b", name: "B", type: 1, api: "https://b.example.com")
        ])
        try await database.upsert(sites: [
            Site(key: "a", name: "A2", type: 1, api: "https://a.example.com")
        ])

        let sites = try await database.sites()
        #expect(sites.count == 2)
        #expect(sites.first { $0.key == "a" }?.name == "A2")
    }

    @Test("播放进度按站点+ID 存储")
    func playbackPosition() async throws {
        let database = InMemoryAppDatabase()
        let key = PlaybackKey(siteKey: "cat", vodID: "1001")
        #expect(try await database.playbackPosition(vodKey: key.storageKey) == nil)

        try await database.save(playbackPosition: 123.5, vodKey: key.storageKey)
        #expect(try await database.playbackPosition(vodKey: key.storageKey) == 123.5)
        #expect(key.storageKey == "cat#1001")
    }

    @Test("搜索历史去重并置于最前")
    func searchHistory() async throws {
        let database = InMemoryAppDatabase()
        try await database.append(searchKeyword: "海贼")
        try await database.append(searchKeyword: "火影")
        try await database.append(searchKeyword: "海贼")

        #expect(try await database.searchHistory() == ["海贼", "火影"])
    }
}
