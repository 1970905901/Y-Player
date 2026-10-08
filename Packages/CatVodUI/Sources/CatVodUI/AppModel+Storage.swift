import CatVodCore
import CatVodStore
import Foundation

// 「数据」相关的接线：把收藏 / 播放进度从内存实现换成 GRDB 落库（M08b）。
//
// 设计要点：
// - **打开失败必须能降级**：磁盘不可写、库损坏时退回内存实现，并在设置页如实说明
//   （宁可这一轮不记忆，也不能让详情页/追剧页打不开）；
// - 数据库路径放在 Application Support 下（与源缓存同级），不进 iCloud 备份范围之外的位置；
// - 失败留痕统一从 `GRDBDatabase.failures` 读，设置页显示最近几条。

public extension AppModel {
    /// 打开（或创建）本地库；失败返回 nil，由调用方退回内存实现。
    ///
    /// - Parameter url: 库文件路径；传 nil 时用 ``storageDatabaseURL()``（在函数体内解析，
    ///   避免把静态成员写进默认参数）。
    static func openStorageDatabase(at url: URL? = nil) -> GRDBDatabase? {
        let target = url ?? storageDatabaseURL()
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try GRDBDatabase(path: target.path)
        } catch {
            return nil
        }
    }

    /// 本地库路径（Application Support/YPlayer/YPlayer.sqlite）。
    static func storageDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("YPlayer", isDirectory: true)
            .appendingPathComponent("YPlayer.sqlite")
    }

    /// 存储失败留痕（设置 → 数据 展示；空数组表示一切正常）。
    var storageFailures: [String] {
        storageDatabase?.failures.recent ?? []
    }

    /// 存储状态说明：落库路径 / 内存降级原因。
    var storageSummary: String {
        guard storageDatabase != nil else {
            return "内存（未落库）：\(storageNotice)"
        }
        return "已落库：\(Self.storageDatabaseURL().path)"
    }

    /// 下载目录（离线下载的落地位置）。
    ///
    /// 与本地库同级放在 Application Support 下；离线下载本身尚未接入，
    /// 所以这个目录通常还不存在 —— 「下载管理」页按 0 字节呈现（空态是真实状态）。
    static var downloadDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("YPlayer", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}
