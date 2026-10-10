import CatVodCore
import Foundation
import GRDB

/// 播放进度的 GRDB 实现（协议见 ``PlaybackProgressStore``）。
///
/// 存储形态：主键 ``PlaybackKey/storageKey``，另冗余 `siteKey` / `vodID` 两列；
/// `metadata`（片名/封面/站源/线路/集名）存 JSON 文本，读取失败时退化为空元数据而不是整条记录失败。
public struct GRDBPlaybackProgressStore: PlaybackProgressStore {
    private static let columns = [
        "vodKey", "siteKey", "vodID", "position", "duration", "isFinished",
        "opening", "ending", "episodeIndex", "updatedAt", "metadata",
    ].joined(separator: ", ")

    private let database: GRDBDatabase

    public init(database: GRDBDatabase) {
        self.database = database
    }

    /// 存储失败留痕（诊断用）。
    public var failureMessages: [String] {
        database.failures.recent
    }

    public func progress(for key: PlaybackKey) async -> PlaybackProgress? {
        let sql = "SELECT \(Self.columns) FROM playbackProgress WHERE vodKey = ?"
        let storageKey = key.storageKey
        // 与收藏同一处理：`read` 会把 `Row?` 再包一层，改用 `fetchAll(...).first`。
        let rows = database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [storageKey])
        }
        guard let row = rows?.first else {
            return nil
        }
        return Self.progress(from: row)
    }

    public func save(_ progress: PlaybackProgress) async {
        let sql = """
        INSERT OR REPLACE INTO playbackProgress
        (vodKey, siteKey, vodID, position, duration, isFinished, opening, ending, episodeIndex, updatedAt, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let metadata = Self.encode(progress.metadata)
        database.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    progress.key.storageKey,
                    progress.key.siteKey,
                    progress.key.vodID,
                    progress.position,
                    progress.duration,
                    progress.isFinished ? 1 : 0,
                    progress.opening,
                    progress.ending,
                    progress.episodeIndex,
                    progress.updatedAt.timeIntervalSince1970,
                    metadata,
                ]
            )
        }
    }

    public func clear(for key: PlaybackKey) async {
        let storageKey = key.storageKey
        database.write { db in
            try db.execute(sql: "DELETE FROM playbackProgress WHERE vodKey = ?", arguments: [storageKey])
        }
    }

    public func all() async -> [PlaybackProgress] {
        let sql = "SELECT \(Self.columns) FROM playbackProgress ORDER BY updatedAt DESC"
        let rows = database.read { db in
            try Row.fetchAll(db, sql: sql)
        }
        return (rows ?? []).map(Self.progress(from:))
    }

    /// 记录条数（测试与诊断用）。
    public func count() async -> Int {
        database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackProgress") ?? 0
        } ?? 0
    }

    // MARK: - 行映射

    private static func progress(from row: Row) -> PlaybackProgress {
        let storageKey: String = row["vodKey"]
        let siteKey: String = row["siteKey"]
        let vodID: String = row["vodID"]
        let position: Double = row["position"]
        let duration: Double = row["duration"]
        let isFinished: Int = row["isFinished"]
        let opening: Double = row["opening"]
        let ending: Double = row["ending"]
        let episodeIndex: Int = row["episodeIndex"]
        let updatedAt: Double = row["updatedAt"]
        let metadata: String = row["metadata"]
        return PlaybackProgress(
            key: PlaybackKey(siteKey: siteKey, vodID: vodID.isEmpty ? storageKey : vodID),
            position: position,
            duration: duration,
            isFinished: isFinished != 0,
            opening: opening,
            ending: ending,
            episodeIndex: episodeIndex,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            metadata: decode(metadata)
        )
    }

    private static func encode(_ metadata: PlaybackEntryMetadata) -> String {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decode(_ text: String) -> PlaybackEntryMetadata {
        guard let data = text.data(using: .utf8) else {
            return PlaybackEntryMetadata()
        }
        return (try? JSONDecoder().decode(PlaybackEntryMetadata.self, from: data)) ?? PlaybackEntryMetadata()
    }
}
