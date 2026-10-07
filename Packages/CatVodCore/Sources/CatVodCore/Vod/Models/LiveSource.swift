import Foundation

/// 直播源。
///
/// 说明：本文件先落地点播配置必需的字段，完整字段表（Group / Channel / Catchup / EPG / DRM 等）
/// 在 M7「直播 + JS Spider」里程碑按 webhtv `docs/integration/live.md` 补齐，
/// 届时会同步更新 `docs/协议兼容矩阵.md`。
public struct LiveSource: Codable, Sendable, Hashable, Identifiable {
    /// 展示名，同时是直播配置的唯一标识。
    public var name: String
    /// 运行时类型：`0` TXT/M3U/JSON 直读，`3` Spider。
    public var type: Int
    /// `type=3` 时的 Spider 入口（`.js` / `csp_*` / `http.../spider/...`）。
    public var api: String
    /// 直播源地址（TXT / M3U / JSON），或 Spider 的输入 URL。
    public var url: String
    /// Spider 扩展参数。
    public var ext: AnyJSONValue
    /// 源专属 JAR；为空时继承顶层 `spider`。
    public var jar: String
    /// EPG 地址。
    public var epg: String
    /// 图标。
    public var logo: String
    /// 请求 header。
    public var header: [String: String]
    /// WebView 点击脚本。
    public var click: String
    /// 播放超时秒数。
    public var timeout: Int
    /// 自定义 User-Agent。
    public var ua: String

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        type = container.lenientInt(.type)
        api = container.lenientString(.api)
        url = container.lenientString(.url)
        ext = container.lenientJSON(.ext) ?? .null
        jar = container.lenientString(.jar)
        epg = container.lenientString(.epg)
        logo = container.lenientString(.logo)
        header = container.lenientStringMap(.header)
        click = container.lenientString(.click)
        timeout = max(container.lenientInt(.timeout, default: 15), 1)
        let directUA = container.lenientString(.ua)
        if directUA.isEmpty {
            // 部分源使用 `userAgent` 写法。
            let aliases = try decoder.container(keyedBy: AliasKeys.self)
            ua = aliases.lenientString(.userAgent)
        } else {
            ua = directUA
        }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case api
        case url
        case ext
        case jar
        case epg
        case logo
        case header
        case click
        case timeout
        case ua
    }

    /// `ua` 的别名键；只用于解码。
    private enum AliasKeys: String, CodingKey {
        case userAgent
    }
}
