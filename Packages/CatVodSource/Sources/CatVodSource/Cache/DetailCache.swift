import CatVodCore
import Foundation

/// 详情缓存（内存 + TTL）。
///
/// 目的：详情页（线路 / 选集）在一次浏览里会被反复打开（从列表返回再进、切线路再回来），
/// 每次都重建请求既慢又容易被站点限流。
///
/// **挡板（哪些情况不缓存）** —— 宁可少缓存，也不要让用户看到过期或会话态数据：
/// 1. **设置类 / Spider 站点**：`type=3`（js2p 的 CatSpider HTTP、JAR、Python）的详情可能携带
///    会话态信息（本地 Node 端口、动态生成的 api/url），缓存后重新进入会拿到失效地址 → 不缓存；
/// 2. **失败或空结果**：`msg` 非空（上游约定「msg 非空视为错误响应」）或 `list` 为空 → 不缓存，
///    否则等于把一次偶发故障固化下来；
/// 3. **显式失效**：`invalidate` / `invalidateAll` 与 `forceRefresh`（下拉刷新、换源、重载配置前）必须能绕过缓存。
///
/// ⚠️ 说明：上游 `VodDetailCache` 的**具体判定条件尚未取得源码核对**
/// （`FongMi/TV` 下按常见路径 404，见 `docs/任务记录/M02P5-详情缓存.md` 的待校准项），
/// 因此本实现按上述原则自定档板，拿到上游源码后再逐条校准；不要把当前条件当作「逐行对齐上游」。
public actor DetailCache {
    /// 缓存配置。
    public struct Configuration: Sendable {
        /// 条目有效期（秒）。默认 300（5 分钟）：详情里的播放地址多为短时效，TTL 不宜长。
        public var ttl: TimeInterval
        /// 容量上限；超出后按写入顺序淘汰最旧条目。
        public var capacity: Int

        public init(ttl: TimeInterval = 300, capacity: Int = 64) {
            self.ttl = ttl
            self.capacity = capacity
        }
    }

    /// 运行统计：用于验证挡板是否生效、排查「为什么没走缓存」。
    public struct Statistics: Sendable, Equatable {
        public var hits = 0
        public var misses = 0
        public var stores = 0
        public var bypasses = 0
        public var count = 0

        /// 缓存是否为空。
        ///
        /// 这里的 `count` 是**计数字段**而不是集合；`isEmpty` 只是给调用方（含测试）一个更可读的名字。
        /// 因此对 `empty_count` 规则做单行豁免，而不是把语义绕成 `count < 1`。
        public var isEmpty: Bool {
            // swiftlint:disable:next empty_count
            count == 0
        }

        public init() { }
    }

    private struct Entry: Sendable {
        let result: SpiderResult
        let storedAt: Date
    }

    private let configuration: Configuration
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var counters = Statistics()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 缓存键：站点 key + vodID。
    nonisolated public static func key(site: Site, vodID: String) -> String {
        "\(site.key)|\(vodID)"
    }

    /// 挡板 1：该站点的详情是否允许缓存。
    ///
    /// 只有 CMS 通道（`type 0/1/2/4`）允许缓存；`type=3` 的 Spider / 设置类站点一律直连不缓存。
    nonisolated public static func shouldCache(site: Site) -> Bool {
        site.kind != .spider
    }

    /// 挡板 2：该结果是否值得缓存。
    nonisolated public static func isCacheable(_ result: SpiderResult) -> Bool {
        guard !result.list.isEmpty else {
            return false
        }
        return result.msg.isEmpty
    }

    /// 读取缓存；过期即视为未命中并删除该条目。
    public func result(site: Site, vodID: String, now: Date = Date()) -> SpiderResult? {
        guard Self.shouldCache(site: site) else {
            counters.bypasses += 1
            return nil
        }
        let cacheKey = Self.key(site: site, vodID: vodID)
        guard let entry = entries[cacheKey] else {
            counters.misses += 1
            return nil
        }
        if now.timeIntervalSince(entry.storedAt) > configuration.ttl {
            remove(cacheKey)
            counters.misses += 1
            return nil
        }
        counters.hits += 1
        return entry.result
    }

    /// 写入缓存；不满足挡板时返回 false（调用方据此知道「这次没有缓存」）。
    @discardableResult
    public func store(_ result: SpiderResult, site: Site, vodID: String, now: Date = Date()) -> Bool {
        guard Self.shouldCache(site: site), Self.isCacheable(result) else {
            counters.bypasses += 1
            return false
        }
        let cacheKey = Self.key(site: site, vodID: vodID)
        if entries[cacheKey] == nil {
            order.append(cacheKey)
        }
        entries[cacheKey] = Entry(result: result, storedAt: now)
        counters.stores += 1
        evictIfNeeded()
        counters.count = entries.count
        return true
    }

    /// 失效单条（例如「换源」后要拿新线路）。
    public func invalidate(site: Site, vodID: String) {
        remove(Self.key(site: site, vodID: vodID))
    }

    /// 清空全部（换配置 / 重载源时调用）。
    public func invalidateAll() {
        entries.removeAll()
        order.removeAll()
        counters.count = 0
    }

    /// 当前统计快照。
    public func statistics() -> Statistics {
        var snapshot = counters
        snapshot.count = entries.count
        return snapshot
    }

    // MARK: - 内部

    private func remove(_ cacheKey: String) {
        entries[cacheKey] = nil
        order.removeAll { $0 == cacheKey }
        counters.count = entries.count
    }

    /// 容量淘汰：按写入顺序移除最旧条目（FIFO，够用且可预测）。
    private func evictIfNeeded() {
        let limit = max(configuration.capacity, 1)
        while entries.count > limit, let oldest = order.first {
            remove(oldest)
        }
    }
}
