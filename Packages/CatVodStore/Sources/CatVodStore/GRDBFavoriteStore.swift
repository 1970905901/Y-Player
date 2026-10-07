import CatVodCore
import Foundation
import GRDB

/// 收藏的 GRDB 实现（协议见 ``FavoriteStore``）。
///
/// 存储形态：一行的主键是 ``PlaybackKey/storageKey``（`站点 key#视频 ID`），
/// 同时**冗余存** `siteKey` / `vodID` 两列 —— 这样读取时不必反解字符串，
/// 也为将来「按站点统计/清理」留了索引位。
public struct GRDBFavoriteStore: FavoriteStore {
    /// 查询用的列清单（显式列出，避免将来加列时读取出错）。
    private static let columns = "vodKey, siteKey, vodID, vodName, picture, siteName, lineName, episodeName, addedAt"

    private let database: GRDBDatabase

    public init(database: GRDBDatabase) {
        self.database = database
    }

    /// 存储失败留痕（诊断用）。
    public var failureMessages: [String] {
        database.failures.recent
    }

    public func favorites() async -> [Favorite] {
        let sql = "SELECT \(Self.columns) FROM favorite ORDER BY addedAt DESC"
        let rows = database.read { db in
            try Row.fetchAll(db, sql: sql)
        }
        return (rows ?? []).map(Self.favorite(from:))
    }

    public func favorite(for key: PlaybackKey) async -> Favorite? {
        let sql = "SELECT \(Self.columns) FROM favorite WHERE vodKey = ?"
        let storageKey = key.storageKey
        let row = database.read { db in
            try Row.fetchOne(db, sql: sql, arguments: [storageKey])
        }
        return row.map(Self.favorite(from:))
    }

    public func add(_ favorite: Favorite) async {
        let sql = """
        INSERT OR REPLACE INTO favorite
        (vodKey, siteKey, vodID, vodName, picture, siteName, lineName, episodeName, addedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        database.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    favorite.key.storageKey,
                    favorite.key.siteKey,
                    favorite.key.vodID,
                    favorite.vodName,
                    favorite.picture,
                    favorite.siteName,
                    favorite.lineName,
                    favorite.episodeName,
                    favorite.addedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    public func remove(for key: PlaybackKey) async {
        await removeAll(for: [key])
    }

    public func removeAll(for keys: [PlaybackKey]) async {
        let storageKeys = keys.map(\.storageKey)
        guard !storageKeys.isEmpty else {
            return
        }
        // 逐条删除（不用 `IN (?, …)`）：SQLite 的占位符上限与拼接长度都不值得在这里冒险，
        // 「追剧」页多选删除的量级也很小。
        database.write { db in
            let sql = "DELETE FROM favorite WHERE vodKey = ?"
            for storageKey in storageKeys {
                try db.execute(sql: sql, arguments: [storageKey])
            }
        }
    }

    public func count() async -> Int {
        database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite") ?? 0
        } ?? 0
    }

    /// 行 → 收藏。
    private static func favorite(from row: Row) -> Favorite {
        let storageKey: String = row["vodKey"]
        let siteKey: String = row["siteKey"]
        let vodID: String = row["vodID"]
        let vodName: String = row["vodName"]
        let picture: String = row["picture"]
        let siteName: String = row["siteName"]
        let lineName: String = row["lineName"]
        let episodeName: String = row["episodeName"]
        let addedAt: Double = row["addedAt"]
        return Favorite(
            key: PlaybackKey(siteKey: siteKey, vodID: vodID.isEmpty ? storageKey : vodID),
            vodName: vodName,
            picture: picture,
            siteName: siteName,
            lineName: lineName,
            episodeName: episodeName,
            addedAt: Date(timeIntervalSince1970: addedAt)
        )
    }
}
