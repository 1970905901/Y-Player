import CatVodSource
import Foundation

/// 设备存储占用快照（设置 → 数据 → 下载管理顶部的空间条）。
///
/// 对应参考图的那一行图例：`总空间 127.9G` / `已用 63.8G` / `下载 0B`。
/// 三个数字**都来自真实查询**：前两个问文件系统卷容量，第三个统计下载目录的实际占用
/// （下载目录里没文件时这里就是 0 —— 空态是真实状态，不是占位；离线下载从 M10 起已可用）。
public enum StorageSpace {
    /// 一次查询的结果。
    public struct Snapshot: Sendable, Equatable {
        /// 卷总容量。
        public var totalBytes: Int64
        /// 卷已用容量（总容量 − 可用容量）。
        public var usedBytes: Int64
        /// 下载目录占用。
        public var downloadBytes: Int64

        public init(totalBytes: Int64 = 0, usedBytes: Int64 = 0, downloadBytes: Int64 = 0) {
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
            self.downloadBytes = downloadBytes
        }

        /// 已用占比（0…1）；总容量读不到时为 0。
        public var usedRatio: Double {
            guard totalBytes > 0 else {
                return 0
            }
            return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
        }

        /// 下载占用占比（0…1）；用于在进度条上叠一小段绿色。
        public var downloadRatio: Double {
            guard totalBytes > 0 else {
                return 0
            }
            return min(max(Double(downloadBytes) / Double(totalBytes), 0), 1)
        }

        public var formattedTotal: String {
            Self.format(totalBytes)
        }

        public var formattedUsed: String {
            Self.format(usedBytes)
        }

        public var formattedDownload: String {
            Self.format(downloadBytes)
        }

        /// 人类可读大小；与接口缓存 / 首页缓存共用同一套格式化（`ByteCountFormatter(.file)`）。
        public static func format(_ byteCount: Int64) -> String {
            SourceCacheStore.Summary.format(byteCount: byteCount)
        }
    }

    /// 人类可读大小（``Snapshot/format(_:)`` 的转发）：页面里可直接 `StorageSpace.format(…)`。
    public static func format(_ byteCount: Int64) -> String {
        Snapshot.format(byteCount)
    }

    /// 查询存储占用。
    ///
    /// - Parameter downloadDirectory: 下载目录；传 nil 或目录不存在时下载占用按 0 计。
    public static func snapshot(
        downloadDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Snapshot {
        let probeURL = downloadDirectory?.deletingLastPathComponent()
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try? probeURL.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        // 优先用「重要用途可用容量」（iOS 会考虑可清理空间），拿不到再退回普通可用容量。
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let used = max(total - available, 0)
        return Snapshot(
            totalBytes: total,
            usedBytes: used,
            downloadBytes: directoryByteCount(downloadDirectory, fileManager: fileManager)
        )
    }

    /// 目录（递归）占用；目录不存在返回 0。
    public static func directoryByteCount(_ url: URL?, fileManager: FileManager = .default) -> Int64 {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else {
                continue
            }
            // 优先用「实际分配大小」：下载的分片文件按块对齐，用它更接近系统设置里看到的占用。
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
