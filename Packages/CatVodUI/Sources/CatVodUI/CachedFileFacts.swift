import Foundation

/// 缓存文件的两项事实：**多大**、**什么时候写的**（M17P1）。
///
/// 两处读者：
/// - 接口管理页 —— 「我这份配置是新版吗」：摘要只说明**是哪一份**，时间和大小才是线索
///   （本轮就是被这个问题问住的：拿到的 bundle 是 8 月 1 日的，界面却看不出新旧）；
/// - 诊断报告 —— 贴给别人看。
///
/// 读不到就给 nil，由调用方决定写成「—」还是整行不显示 —— 这里不编默认值。
enum CachedFileFacts {
    /// 人类可读大小（与缓存 / 存储那几处共用 `StorageSpace.format`）。
    static func size(of url: URL?) -> String? {
        guard let bytes = byteCount(of: url) else {
            return nil
        }
        return StorageSpace.format(bytes)
    }

    /// 写入时间。
    static func modifiedAt(of url: URL?) -> Date? {
        guard let attributes = attributes(of: url) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private static func byteCount(of url: URL?) -> Int64? {
        guard let size = attributes(of: url)?[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func attributes(of url: URL?) -> [FileAttributeKey: Any]? {
        guard let url else {
            return nil
        }
        return try? FileManager.default.attributesOfItem(atPath: url.path)
    }
}
