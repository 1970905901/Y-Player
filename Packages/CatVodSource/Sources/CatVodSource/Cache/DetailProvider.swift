import CatVodCore
import Foundation

/// 详情获取：走缓存优先，不可缓存的站点（Spider / 设置类）直连。
///
/// 用法：`AppModel.makeDetailProvider()` 持有一个共享的 ``DetailCache``，
/// 这样「列表 → 详情 → 返回 → 再进」不会重复打站点接口。
///
/// 客户端用 ``SiteClient``（门面）而不是 `CMSClient`：js2p 的 JS 源站点是 `type=3`，
/// 详情必须走 CatSpider HTTP 协议；对 CMS 站点行为与以前完全一致。
public struct DetailProvider: Sendable {
    public var client: SiteClient
    public var cache: DetailCache

    public init(client: SiteClient, cache: DetailCache = DetailCache()) {
        self.client = client
        self.cache = cache
    }

    /// 取详情。
    ///
    /// - Parameter forceRefresh: 跳过「读缓存」（仍按挡板决定是否写入），用于下拉刷新与换源。
    public func detail(site: Site, vodID: String, forceRefresh: Bool = false) async throws -> SpiderResult {
        if !forceRefresh, let cached = await cache.result(site: site, vodID: vodID) {
            return cached
        }
        let fresh = try await client.detail(site: site, vodID: vodID)
        await cache.store(fresh, site: site, vodID: vodID)
        return fresh
    }

    /// 失效单条详情。
    public func invalidate(site: Site, vodID: String) async {
        await cache.invalidate(site: site, vodID: vodID)
    }

    /// 清空缓存（重载配置 / 换源前调用）。
    public func invalidateAll() async {
        await cache.invalidateAll()
    }

    /// 缓存统计（调试与人工验收用）。
    public func cacheStatistics() async -> DetailCache.Statistics {
        await cache.statistics()
    }
}
