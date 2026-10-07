import Foundation
import GRDB

/// GRDB 数据库：持有 `DatabaseQueue`，负责建表（迁移）与失败留痕。
///
/// 设计要点：
/// - **迁移**用 `DatabaseMigrator`：`CREATE TABLE` 只出现在迁移里，后续加字段只需追加一次
///   `registerMigration`（升级路径可追溯）；
/// - **读写**各包一层，把 GRDB 的 throw 收敛成「返回 nil/false + 记一条原因」：
///   收藏/进度的协议方法不 throws（M2 定的契约），但仓库不允许静默失败，因此统一留痕
///   （见 ``StorageFailureRecorder``）；
/// - 时间统一存 `REAL`（`timeIntervalSince1970`）：显式化表示，避免 Date 编解码策略的隐式差异；
/// - 展示元数据（片名/封面/线路/集名）以 **JSON 文本一列**存储，避免为展示字段频繁改表。
public final class GRDBDatabase: Sendable {
    private let queue: DatabaseQueue

    /// 失败留痕；界面与诊断可以读它，避免「存不上但没人知道」。
    public let failures = StorageFailureRecorder()

    /// 打开/创建磁盘库并执行迁移。
    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try Self.migrate(queue)
    }

    /// 内存库：单测用，也是「磁盘不可用」时 ``AppDatabase`` 降级方案的底座。
    public init() throws {
        queue = try DatabaseQueue()
        try Self.migrate(queue)
    }

    /// 库文件路径；内存库为 `:memory:`。
    public var path: String {
        queue.path
    }

    /// 读；失败返回 nil 并留痕。
    func read<T>(_ body: @Sendable (Database) throws -> T) -> T? {
        do {
            return try queue.read(body)
        } catch {
            failures.record("读取失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 写；成功返回 true，失败留痕。
    @discardableResult
    func write(_ body: @Sendable (Database) throws -> Void) -> Bool {
        do {
            try queue.write(body)
            return true
        } catch {
            failures.record("写入失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 迁移

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.core") { db in
            try db.create(table: "favorite") { t in
                t.primaryKey("vodKey", .text)
                t.column("siteKey", .text).notNull()
                t.column("vodID", .text).notNull()
                t.column("vodName", .text).notNull().defaults(to: "")
                t.column("picture", .text).notNull().defaults(to: "")
                t.column("siteName", .text).notNull().defaults(to: "")
                t.column("lineName", .text).notNull().defaults(to: "")
                t.column("episodeName", .text).notNull().defaults(to: "")
                t.column("addedAt", .double).notNull()
            }
            try db.create(table: "playbackProgress") { t in
                t.primaryKey("vodKey", .text)
                t.column("siteKey", .text).notNull()
                t.column("vodID", .text).notNull()
                t.column("position", .double).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("isFinished", .integer).notNull().defaults(to: 0)
                t.column("episodeIndex", .integer).notNull().defaults(to: -1)
                t.column("updatedAt", .double).notNull()
                t.column("metadata", .text).notNull().defaults(to: "{}")
            }
            // 下面两张表当前只被 ``AppDatabase`` 用到（站点清单 / 搜索历史），
            // 一起建好，M8b 接 UI 时不必再改迁移。
            try db.create(table: "searchHistory") { t in
                t.primaryKey("keyword", .text)
                t.column("searchedAt", .double).notNull()
            }
            try db.create(table: "site") { t in
                t.primaryKey("key", .text)
                t.column("payload", .text).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }
        try migrator.migrate(queue)
    }
}
