import CatVodCore
import Foundation

/// 接口（源配置）缓存管理。
///
/// 背景：``SourceRepository`` 会把配置落盘（JSON 存原文本，JS 源是 **6 MB** 的 bundle + `.md5` 摘要），
/// 但此前**只有写入、没有管理**：换一个接口地址后旧缓存会永久残留（每个 JS 源 ≈ 6 MB）。
///
/// 本类型负责「看得见 + 清得掉 + 有上限」：
/// - ``entries(currentURL:)`` / ``summary(currentURL:)``：条目、占用、最近更新时间、哪些属于当前接口；
/// - ``clear()`` / ``remove(fileName:)``：手动清理（UI 提供按钮）；
/// - ``pruneOrphans(currentURL:)``：清掉**非当前接口**的残留；
/// - ``enforceLimit(currentURL:)``：超过 ``maxByteCount`` 时按最近修改时间淘汰旧条目，
///   **永不删除当前接口的缓存**（否则用户每次切换回来都要重下 6 MB）。
/// 本类型持有 `FileManager`（并非 `Sendable`），因此**不标 `Sendable`**：
/// 它是一个无状态门面，按需构造、用完即弃（UI 在 `@MainActor` 上调用），不需要跨 actor 传递。
public struct SourceCacheStore {
    /// 单个缓存文件。
    public struct Entry: Sendable, Hashable {
        /// 缓存文件名，如 `config-<md5>.js`、`config-<md5>.js.md5`、`config-<md5>.json`。
        public var fileName: String
        public var byteCount: Int64
        public var modifiedAt: Date
        /// 是否为 `.md5` 摘要文件。
        public var isDigest: Bool
        /// 是否属于当前接口（由 `currentURL` 推导出的缓存文件名）。
        public var isCurrent: Bool

        public init(
            fileName: String,
            byteCount: Int64,
            modifiedAt: Date,
            isDigest: Bool,
            isCurrent: Bool
        ) {
            self.fileName = fileName
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
            self.isDigest = isDigest
            self.isCurrent = isCurrent
        }
    }

    /// 缓存概览（接口管理页直接展示）。
    public struct Summary: Sendable, Hashable {
        public var entryCount: Int
        public var totalByteCount: Int64
        /// 属于当前接口的条目数。
        public var currentEntryCount: Int
        /// 非当前接口占用的字节数（可清理的量）。
        public var orphanByteCount: Int64
        public var latestModifiedAt: Date?

        public var formattedTotalSize: String {
            Self.format(byteCount: totalByteCount)
        }

        public var formattedOrphanSize: String {
            Self.format(byteCount: orphanByteCount)
        }

        public init(
            entryCount: Int = 0,
            totalByteCount: Int64 = 0,
            currentEntryCount: Int = 0,
            orphanByteCount: Int64 = 0,
            latestModifiedAt: Date? = nil
        ) {
            self.entryCount = entryCount
            self.totalByteCount = totalByteCount
            self.currentEntryCount = currentEntryCount
            self.orphanByteCount = orphanByteCount
            self.latestModifiedAt = latestModifiedAt
        }

        /// 人类可读的大小（`6.3 MB`）。集中在一处，避免 UI 各自格式化。
        public static func format(byteCount: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            return formatter.string(fromByteCount: max(byteCount, 0))
        }
    }

    public var directory: URL
    public var fileManager: FileManager
    /// 容量上限；默认 64 MB（约 10 个 JS 源 bundle）。超过后由 ``enforceLimit(currentURL:)`` 淘汰。
    public var maxByteCount: Int64

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        maxByteCount: Int64 = 64 * 1024 * 1024
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maxByteCount = maxByteCount
    }

    /// 列出全部缓存条目（按最近修改时间倒序）。
    public func entries(currentURL: URL? = nil) throws -> [Entry] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        let currentNames = Self.cacheFileNames(for: currentURL)
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> Entry? in
                let url = directory.appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                    return nil
                }
                let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
                let size = isDirectory
                    ? Self.byteCount(ofDirectory: url, fileManager: fileManager)
                    : (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
                return Entry(
                    fileName: name,
                    byteCount: size,
                    modifiedAt: modified,
                    isDigest: !isDirectory && name.hasSuffix(ConfigLocator.digestSuffix),
                    isCurrent: currentNames.contains(name)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 概览。
    public func summary(currentURL: URL? = nil) throws -> Summary {
        let all = try entries(currentURL: currentURL)
        let current = all.filter(\.isCurrent)
        let orphans = all.filter { !$0.isCurrent }
        return Summary(
            entryCount: all.count,
            totalByteCount: all.reduce(0) { $0 + $1.byteCount },
            currentEntryCount: current.count,
            orphanByteCount: orphans.reduce(0) { $0 + $1.byteCount },
            latestModifiedAt: all.map(\.modifiedAt).max()
        )
    }

    /// 当前接口对应的缓存条目名（`ConfigLocator` 是唯一的命名来源，避免两处规则漂移）。
    ///
    /// JS 源的缓存**是一个目录**（`bundle-<md5(url)>/`，内含 `index.js` 与 `index.js.md5`）：
    /// 参考实现同样把运行目录固定成「一个 bundle 一个目录」，我们照此对齐，
    /// 这样清理与淘汰都只需按目录名进行。
    public static func cacheFileNames(for url: URL?) -> Set<String> {
        guard let url, let source = ConfigLocator.locate(url.absoluteString),
              let configURL = source.url
        else {
            return []
        }
        if source.kind == .javaScript {
            return [ConfigLocator.scriptCacheDirectoryName(for: configURL)]
        }
        return [source.cacheFileName]
    }

    /// 目录占用（JS 源的缓存目录里是 bundle + 摘要，根目录层级够用）。
    private static func byteCount(ofDirectory url: URL, fileManager: FileManager) -> Int64 {
        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.reduce(0) { total, name in
            let child = url.appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: child.path))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }
}
