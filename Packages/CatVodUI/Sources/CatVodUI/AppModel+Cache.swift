import CatVodCore
import CatVodSource
import Foundation

// 「设置 → 数据 → 缓存管理」的接线：首页缓存读写 + 两处缓存的合计占用。
//
// 为什么放扩展文件：AppModel 主体的职责是「配置 / 站点 / 播放」状态，缓存是另一件事；
// 与 `AppModel+Storage.swift`（落库）、`AppModel+LocalProxy.swift`（本机服务）同一套切分方式。

public extension AppModel {
    /// 首页缓存目录（`YPlayer/Sources/Home`，与接口缓存同根，便于一起统计「全部缓存」）。
    var homeCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("Home", isDirectory: true)
    }

    /// 首页（分类/列表）结果的落盘缓存。
    var homeCache: HomeCacheStore {
        HomeCacheStore(directory: homeCacheDirectory)
    }

    /// 读首页缓存：命中就**不发任何请求**（有效期来自设置 → 数据 → 缓存管理）。
    func cachedHomeResult(_ key: HomeCacheStore.Key) -> SpiderResult? {
        homeCache.read(key, maxAge: homeCacheLifetime.timeInterval)
    }

    /// 写首页缓存（写不上不影响这次浏览，所以静默）。
    func storeHomeResult(_ result: SpiderResult, key: HomeCacheStore.Key) {
        homeCache.write(result, key: key)
    }

    /// 首页缓存概览（设置页展示「首页缓存数据」的大小）；目录不可读时返回 nil。
    func homeCacheSummary() -> HomeCacheStore.Summary? {
        try? homeCache.summary()
    }

    /// 清空首页缓存，返回删除的文件数。
    @discardableResult
    func clearHomeCache() -> Int {
        (try? homeCache.clear()) ?? 0
    }

    /// 首页缓存占用（字节）。
    var homeCacheByteCount: Int64 {
        homeCacheSummary()?.byteCount ?? 0
    }

    /// 接口缓存占用（字节）。
    var sourceCacheByteCount: Int64 {
        sourceCacheSummary()?.totalByteCount ?? 0
    }

    /// 两处缓存的合计 —— 参考图里「全部缓存 (42.34MB)」的口径就是它们之和
    /// （下载占用属于下载管理，本地库属于存储，都不算在缓存里）。
    var totalCacheByteCount: Int64 {
        sourceCacheByteCount + homeCacheByteCount
    }

    /// 「全部缓存」的展示文本。
    var formattedTotalCacheSize: String {
        SourceCacheStore.Summary.format(byteCount: totalCacheByteCount)
    }

    /// 清空全部缓存（接口 + 首页），返回删除的条目数。
    @discardableResult
    func clearAllCaches() -> Int {
        clearSourceCache() + clearHomeCache()
    }
}
