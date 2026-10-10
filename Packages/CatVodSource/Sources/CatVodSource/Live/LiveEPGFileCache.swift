import CatVodCore
import Foundation

/// 文件形态节目单的落盘缓存（M07d7）。
///
/// 存的是**服务器原样给的字节**（gz 就存 gz —— 一份全国性 XMLTV 解压后几十 MB，gz 只有几 MB）；
/// 新鲜度用文件修改时间，判定在 ``EPGFileCachePolicy``（上游 `EpgParser.refreshReason` 那三条）。
///
/// 与 ``SourceCacheStore`` / ``HomeCacheStore`` 同一套做法（目录 + 读写 + clear/summary）；
/// 两点不同：键是**节目单地址的 md5**（地址是外部的，不能直接当文件名），
/// 以及不持有 `FileManager`（Swift 6 下它不是 `Sendable`；与 ``DownloadRunner`` 同一条理由）。
public struct LiveEPGFileCache: Sendable {
    /// 缓存目录（App 里是 `YPlayer/Sources/LiveEPG`）。
    public var directory: URL

    /// 一份缓存。
    public struct Entry: Sendable, Equatable {
        /// 原样字节（可能是 gz）。
        public var data: Data
        /// 落盘时间；新鲜度判定用它（语义与上游看文件 mtime 一致）。
        public var modifiedAt: Date

        public init(data: Data, modifiedAt: Date) {
            self.data = data
            self.modifiedAt = modifiedAt
        }
    }

    /// 概览（缓存管理页展示）。
    public struct Summary: Sendable, Hashable {
        public var entryCount: Int
        public var byteCount: Int64
        public var latestModifiedAt: Date?

        public init(entryCount: Int = 0, byteCount: Int64 = 0, latestModifiedAt: Date? = nil) {
            self.entryCount = entryCount
            self.byteCount = byteCount
            self.latestModifiedAt = latestModifiedAt
        }

        /// 人类可读大小；与接口 / 首页缓存共用同一套格式化，避免三处单位不一致。
        public var formattedSize: String {
            SourceCacheStore.Summary.format(byteCount: byteCount)
        }
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// 缓存文件名（`epg-<md5>.bin`）：同一个地址永远是同一个文件，不同地址不撞。
    ///
    /// 后缀是 `.bin` 而不是 `.xml` / `.gz`：内容可能是压缩过的、也可能不是（按魔数判断），
    /// 起一个中性的名字，别让人以为 `.xml` 就能直接打开。
    public func fileName(for url: String) -> String {
        "epg-\(MD5.hexDigest(of: Data(url.utf8))).bin"
    }

    /// 读一份缓存；没写过 / 读不动都给 nil（调用方按「没有缓存」处理，去联网）。
    public func read(_ url: String) -> Entry? {
        let target = directory.appendingPathComponent(fileName(for: url))
        guard let data = try? Data(contentsOf: target),
              let modified = modifiedAt(target)
        else {
            return nil
        }
        return Entry(data: data, modifiedAt: modified)
    }

    /// 写缓存（失败静默：缓存写不上不该影响这次浏览 —— 与 ``SourceCacheStore`` 的写入侧同一条）。
    public func store(_ data: Data, for url: String) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: directory.appendingPathComponent(fileName(for: url)), options: .atomic)
    }

    /// 清空（缓存管理页的「清空」），返回删除的文件数。
    @discardableResult
    public func clear() -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where !name.hasPrefix(".") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    /// 概览（条数 / 占用 / 最近写入）。
    public func summary() -> Summary {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return Summary()
        }
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        var byteCount: Int64 = 0
        var latest: Date?
        for name in names {
            let target = directory.appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: target.path))?[.size] as? NSNumber
            byteCount += size?.int64Value ?? 0
            if let modified = modifiedAt(target), latest.map({ modified > $0 }) ?? true {
                latest = modified
            }
        }
        return Summary(entryCount: names.count, byteCount: byteCount, latestModifiedAt: latest)
    }

    private func modifiedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
