import Foundation

/// 站点类型。
///
/// 对照 webhtv `docs/integration/vod-site.md` 的「站点类型」表。
public enum SiteKind: Int, Sendable, CaseIterable {
    /// XML API：首页/分类按 XML 解析，分类/详情带 `ac=videolist`。
    case xmlApi = 0
    /// JSON API：分类/详情带 `ac=detail`，筛选参数以 `f={json}` 发送。
    case jsonApi = 1
    /// JSON API 兼容：带 `ac=detail`，不追加 `f`。
    case jsonApiCompat = 2
    /// Spider：按 `api` 分发到 JAR / JS / Python / CatSpider。
    case spider = 3
    /// HTTP API + Base64 ext：首页带 `filter=true`，分类带 `ext={base64}`，播放带 `play`、`flag`。
    case httpApiBase64Ext = 4
}

/// `type=3` 的运行时分发结果。
///
/// 对照 webhtv `docs/integration/vod-site.md` 的分发规则表与 `extensions.md`。
public enum SpiderRuntimeKind: String, Sendable, CaseIterable {
    /// `http.../spider/...`：CatSpider HTTP 协议（本项目 js2p 主接口走这里）。
    case catSpiderHTTP
    /// `*.py` 或含 `.py`：Python 运行时（Apple 平台不支持）。
    case python
    /// `*.js` 或含 `.js`：JS Spider（JavaScriptCore 运行时）。
    case javaScript
    /// `csp_*`：JAR/JAVA Spider（需要 JVM，Apple 平台不支持）。
    case jarJava
    /// 其它：`SpiderNull`，站点不可用。
    case unsupported
}

/// 可用性判定结果。
public enum SiteAvailability: Sendable, Hashable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var reason: String? {
        if case let .unavailable(reason) = self {
            return reason
        }
        return nil
    }
}

/// 站点/直播源 `searchable`、`changeable` 等三态字段语义。
///
/// 对照 webhtv `docs/integration/vod-site.md`：
/// `0` 永久禁用、`1` 启用、`2` 临时禁用但允许 App 恢复。
public enum FeatureAvailability: Int, Sendable, CaseIterable {
    case disabled = 0
    case enabled = 1
    case temporarilyDisabled = 2

    public var isUsable: Bool {
        self != .disabled
    }

    /// 是否允许 App 在运行时自动恢复（仅 `2` 允许）。
    public var allowsAutomaticRecovery: Bool {
        self == .temporarilyDisabled
    }
}
