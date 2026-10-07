import CatVodCore
import Foundation

/// 加载完成的源配置。
public struct LoadedSource: Sendable {
    public enum Kind: String, Sendable {
        /// 普通猫源 JSON 配置。
        case json
        /// JS 源（js2p）bundle：站点清单需由内嵌 Node 执行后提供，此处只给本地文件路径。
        case javaScript
    }

    public var kind: Kind
    /// JSON 配置解析结果；JS 源暂为空配置（站点来自 bundle 的 `/config/sites/list`）。
    public var config: SourceConfig
    /// 配置来源地址（内联配置为 nil）。
    public var originURL: URL?
    /// 本地缓存文件：JSON 是配置文本，JS 是 6 MB bundle（交给 Node 执行）。
    public var cachedURL: URL?
    /// 本地文件摘要（仅 JS 源）。
    public var digest: String?
    /// 是否命中本地缓存（未重新下载）。
    public var usedCache: Bool
    /// 是否因网络失败退回缓存。
    public var usedOfflineFallback: Bool
    /// 配置层告警（站点不可用原因等），供 UI 展示。
    public var warnings: [String]

    public init(
        kind: Kind,
        config: SourceConfig,
        originURL: URL? = nil,
        cachedURL: URL? = nil,
        digest: String? = nil,
        usedCache: Bool = false,
        usedOfflineFallback: Bool = false,
        warnings: [String] = []
    ) {
        self.kind = kind
        self.config = config
        self.originURL = originURL
        self.cachedURL = cachedURL
        self.digest = digest
        self.usedCache = usedCache
        self.usedOfflineFallback = usedOfflineFallback
        self.warnings = warnings
    }
}
