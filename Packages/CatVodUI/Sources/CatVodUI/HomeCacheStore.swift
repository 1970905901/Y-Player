import CatVodCore
import CatVodSource
import Foundation

/// 首页（分类/列表）结果的落盘缓存。
///
/// 对应参考图「缓存管理 → 首页缓存时间 / 首页缓存数据」：键是「站点 + 分类 + 页 + 筛选」，
/// 值是接口返回的 ``SpiderResult`` 原文（`Codable`）。有效期由设置页的
/// ``CacheLifetime`` 决定，命中时首页**不发任何请求**。
///
/// 与 ``SourceCacheStore``（接口配置缓存，落在 `YPlayer/Sources`）分开放在 `YPlayer/Home`：
/// 两者生命周期不同 —— 接口缓存可以随手清掉（下次重下），首页缓存清掉只是下次要重新请求。
///
/// 本类型持有 `FileManager`（并非 `Sendable`），因此**不标 `Sendable`**：它是无状态门面，
/// 按需构造、用完即弃（UI 在 `@MainActor` 上调用）。
public struct HomeCacheStore {
    /// 缓存键：站点 + 分类 + 页 + 筛选（筛选项按 key 排序后参与摘要，顺序不影响命中）。
    public struct Key: Sendable, Hashable {
        public var siteKey: String
        public var categoryID: String
        public var page: Int
        public var extend: [String: String]

        public init(siteKey: String, categoryID: String, page: Int, extend: [String: String] = [:]) {
            self.siteKey = siteKey
            self.categoryID = categoryID
            self.page = page
            self.extend = extend
        }

        /// 参与摘要的文本：固定顺序拼接，保证同一个筛选组合只对应一个文件。
        public var digestSource: String {
            let filters = extend.keys.sorted().map { "\($0)=\(extend[$0] ?? "")" }.joined(separator: "&")
            return "\(siteKey)|\(categoryID)|\(page)|\(filters)"
        }

        /// 缓存文件名（`home-<md5>.json`）。
        public var fileName: String {
            "home-\(MD5.hexDigest(of: Data(digestSource.utf8))).json"
        }
    }

    /// 概览（设置页展示「首页缓存数据」的大小）。
    public struct Summary: Sendable, Hashable {
        public var entryCount: Int
        public var byteCount: Int64
        public var latestModifiedAt: Date?

        public init(entryCount: Int = 0, byteCount: Int64 = 0, latestModifiedAt: Date? = nil) {
            self.entryCount = entryCount
            self.byteCount = byteCount
            self.latestModifiedAt = latestModifiedAt
        }

        /// 人类可读大小；与接口缓存共用同一套格式化，避免两处字号/单位不一致。
        public var formattedSize: String {
            SourceCacheStore.Summary.format(byteCount: byteCount)
        }
    }

    public var directory: URL
    public var fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// 读缓存；过期、文件缺失或内容解析失败都返回 nil（调用方按未命中处理，去联网）。
    public func read(_ key: Key, maxAge: TimeInterval?, now: Date = Date()) -> SpiderResult? {
        let url = directory.appendingPathComponent(key.fileName)
        guard let modified = modifiedAt(url) else {
            return nil
        }
        if let maxAge, now.timeIntervalSince(modified) >= maxAge {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(SpiderResult.self, from: data)
        else {
            return nil
        }
        return result
    }

    /// 写缓存（失败静默：缓存写不上不该影响这次浏览）。
    public func write(_ result: SpiderResult, key: Key) {
        guard let data = try? JSONEncoder().encode(result) else {
            return
        }
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
    }

    /// 清空首页缓存，返回删除的文件数。
    @discardableResult
    public func clear() throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
        var removed = 0
        for name in names {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    /// 概览（条数 / 占用 / 最近写入）。
    public func summary() throws -> Summary {
        guard fileManager.fileExists(atPath: directory.path) else {
            return Summary()
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
        var byteCount: Int64 = 0
        var latest: Date?
        for name in names {
            let url = directory.appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            byteCount += size?.int64Value ?? 0
            if let modified = modifiedAt(url), latest.map({ modified > $0 }) ?? true {
                latest = modified
            }
        }
        return Summary(entryCount: names.count, byteCount: byteCount, latestModifiedAt: latest)
    }

    private func modifiedAt(_ url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
