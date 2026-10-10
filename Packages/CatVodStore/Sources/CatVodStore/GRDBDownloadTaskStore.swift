import CatVodCore
import Foundation
import GRDB

/// 下载任务的 GRDB 实现（协议见 ``DownloadTaskStore``）。
///
/// 三处与播放进度不同、值得写下来的地方：
///
/// 1. `status` 存**原始字符串**而不是序号：以后加状态时，旧库里存着的字符串仍然解得出来
///    （序号会错位，把「失败」读成「排队中」这种错最难查）；
/// 2. `headers` 存 JSON，读取失败退化成**空表**而不是整条记录失败 —— 丢 header 顶多播放时
///    少了鉴权，丢整条会让用户看到「下载记录凭空少了一条」；
/// 3. **恢复策略**：库里若存着 `running`（上次没跑完就被杀了），读出来一律降级成 `waiting`。
///    不这么做，那条死任务会一直占着一个并发位（``DownloadQueue/concurrencyLimit``），
///    而且永远没有东西把它推向完成 —— 表现就是「明明只下着一条，第二条永远排队」。
public struct GRDBDownloadTaskStore: DownloadTaskStore {
    private static let columns = """
    id, siteKey, title, episode, line, url, headers, status, \
    expectedBytes, receivedBytes, failureReason, retryCount, completedSegments, resumeFingerprint, createdAt
    """

    private static let insertSQL = """
    INSERT OR REPLACE INTO downloadTask
    (id, siteKey, title, episode, line, url, headers, status, \
    expectedBytes, receivedBytes, failureReason, retryCount, completedSegments, resumeFingerprint, createdAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    private let database: GRDBDatabase

    public init(database: GRDBDatabase) {
        self.database = database
    }

    /// 存储失败留痕（诊断用）。
    public var failureMessages: [String] {
        database.failures.recent
    }

    public func all() async -> [DownloadTask] {
        let sql = "SELECT \(Self.columns) FROM downloadTask ORDER BY createdAt ASC"
        let rows = database.read { db in
            try Row.fetchAll(db, sql: sql)
        }
        return (rows ?? []).map(Self.task(from:))
    }

    @discardableResult
    public func save(_ task: DownloadTask) -> Bool {
        let arguments: StatementArguments = [
            task.id,
            task.siteKey,
            task.title,
            task.episode,
            task.line,
            task.url,
            Self.encodeHeaders(task.headers),
            task.status.rawValue,
            task.expectedBytes,
            task.receivedBytes,
            task.failureReason,
            task.retryCount,
            task.completedSegments,
            task.resumeFingerprint,
            task.createdAt.timeIntervalSince1970,
        ]
        return database.write { db in
            try db.execute(sql: Self.insertSQL, arguments: arguments)
        }
    }

    @discardableResult
    public func save(_ tasks: [DownloadTask]) -> Bool {
        guard !tasks.isEmpty else {
            return true
        }
        return database.write { db in
            for task in tasks {
                let arguments: StatementArguments = [
                    task.id,
                    task.siteKey,
                    task.title,
                    task.episode,
                    task.line,
                    task.url,
                    Self.encodeHeaders(task.headers),
                    task.status.rawValue,
                    task.expectedBytes,
                    task.receivedBytes,
                    task.failureReason,
                    task.retryCount,
                    task.completedSegments,
                    task.resumeFingerprint,
                    task.createdAt.timeIntervalSince1970,
                ]
                try db.execute(sql: Self.insertSQL, arguments: arguments)
            }
        }
    }

    public func remove(id: String) async {
        database.write { db in
            try db.execute(sql: "DELETE FROM downloadTask WHERE id = ?", arguments: [id])
        }
    }

    public func clear() async {
        database.write { db in
            try db.execute(sql: "DELETE FROM downloadTask")
        }
    }

    public func count() async -> Int {
        database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadTask") ?? 0
        } ?? 0
    }

    // MARK: - 行映射

    private static func task(from row: Row) -> DownloadTask {
        let siteKey: String = row["siteKey"]
        let title: String = row["title"]
        let episode: String = row["episode"]
        let line: String = row["line"]
        let url: String = row["url"]
        let headers: String = row["headers"]
        let status: String = row["status"]
        let expectedBytes: Int64 = row["expectedBytes"]
        let receivedBytes: Int64 = row["receivedBytes"]
        let failureReason: String = row["failureReason"]
        let retryCount: Int = row["retryCount"]
        let completedSegments: Int = row["completedSegments"]
        let resumeFingerprint: String = row["resumeFingerprint"]
        let createdAt: Double = row["createdAt"]
        // 注意：`id` 是从这几个字段**派生**出来的（``DownloadTask/id``），读的时候不还原它 ——
        // 存那一列只是为了让主键稳定、并支持直接按 id 删。
        return DownloadTask(
            siteKey: siteKey,
            title: title,
            episode: episode,
            line: line,
            url: url,
            headers: decodeHeaders(headers),
            status: recoveredStatus(status),
            expectedBytes: expectedBytes,
            receivedBytes: receivedBytes,
            failureReason: failureReason,
            retryCount: retryCount,
            completedSegments: completedSegments,
            resumeFingerprint: resumeFingerprint,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    /// 恢复时的状态降级：`running` → `waiting`。其余原样。
    ///
    /// **认不出来的字符串也回落 `waiting`**：宁可让它重排一次，也不要留一条谁都不认识、
    /// 永远不会动的记录（版本回退时就会遇到这种行）。
    static func recoveredStatus(_ raw: String) -> DownloadTask.Status {
        guard let status = DownloadTask.Status(rawValue: raw) else {
            return .waiting
        }
        return status == .running ? .waiting : status
    }

    private static func encodeHeaders(_ headers: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(headers) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeHeaders(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
