import Foundation

/// 直播源。
///
/// 字段表对照上游 `bean/Live.java` 与 webhtv `docs/integration/live.md`。
/// M01 先落地点播配置必需的字段；**M07a 已补齐直播侧字段与清单解析**
/// （分组 / 频道 / 时移 / EPG 地址拆分，见 `docs/任务记录/M07a-直播模型与清单解析.md`）；
/// EPG 的文件解析与接口拉取已由 M07b / M07c 落地（`Tools/out/upstream/` 里有对照过的上游源码），
/// 直播页与播放接线属 M07c-2，DRM/ClearKey 属内核阶段。
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
    /// 播放器类型（协议保留字段）。
    public var playerType: Int
    /// 请求 Origin。
    public var origin: String
    /// 请求 Referer。
    public var referer: String
    /// 节目单时区（EPG 阶段用）。
    public var timeZone: String
    /// 上次观看位置（`分组名│频道名│…`，由界面写入）。
    public var keep: String
    /// 源级时移配置；频道级优先（见 ``LiveCatchup/decide(major:minor:)``）。
    public var catchup: LiveCatchup?
    /// 解析出来的分组与频道（M07a：``LivePlaylistParser`` 填充）。
    public var groups: [LiveGroup]
    /// 分组名拆分开关（上游字段名就是 `pass`）：true 表示组名里的 `_` 不当密码。
    public var pass: Bool
    /// **`core` 引擎注入**（tvbus 等）。本平台没有对应内核（见 `docs/协议兼容矩阵.md`）。
    ///
    /// 解出来只为**把「为什么这个源用不了」说清**（M20P1）—— 不参与任何播放，
    /// 也不假装支持：以前这个字段被静默丢掉，用户看到的是「取清单失败」这种无头绪的错。
    public var core: AnyJSONValue
    /// 开机自动播放该直播源（上游 `Live.boot`）。
    ///
    /// 上游在「开机自启」里读它；本项目 M07d-9 接上：本地开关在「直播设置 → 启动」，
    /// 启动时由 `RootView` 判定（打开 → 初始落在「直播」Tab）。
    public var boot: Bool

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
        playerType = container.lenientInt(.playerType)
        origin = container.lenientString(.origin)
        referer = container.lenientString(.referer)
        timeZone = container.lenientString(.timeZone)
        keep = container.lenientString(.keep)
        core = container.lenientJSON(.core) ?? .null
        catchup = container.lenientValue(.catchup)
        groups = container.lenientArray(.groups)
        pass = container.lenientBool(.pass)
        boot = container.lenientBool(.boot)
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
        case playerType
        case origin
        case referer
        case timeZone
        case keep
        case catchup
        case groups
        case pass
        case boot
        case core
    }

    // MARK: - 取值语义（对齐上游 Live）

    /// 上游 `getHeaders()`：`header` 表 + `ua`/`origin`/`referer`（后者覆盖同名）。
    public func headers() -> [String: String] {
        var merged = header
        if !ua.isEmpty {
            merged["User-Agent"] = ua
        }
        if !origin.isEmpty {
            merged["Origin"] = origin
        }
        if !referer.isEmpty {
            merged["Referer"] = referer
        }
        return merged
    }

    /// 上游 `getEpgApi()`：`epg` 逗号串里含 `{` 的那一项（EPG 接口地址）。
    ///
    /// 说明：`epg` 允许写成「接口 + XML/GZ 文件」的逗号串（上游 `getEpgApi` / `getEpgXml`），
    /// 这里把拆分逻辑收在模型上，界面与 EPG 阶段直接取。
    public var epgAPI: String {
        for item in epgItems where item.contains("{") {
            return item
        }
        return epg
    }

    /// 上游 `getEpgXml()`：含 `xml` 或 `gz` 的项（XML/GZ 节目单文件）。
    public var epgXML: [String] {
        epgItems.filter { !$0.contains("{") && ($0.contains("xml") || $0.contains("gz")) }
    }

    /// `core` 里的引擎名（`core.type`，如 `tvbus`）；没有 / 认不出就是空串。
    public var coreEngine: String {
        guard case let .object(fields) = core else {
            return ""
        }
        return (fields["type"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这个源是不是靠 `core`（内核注入）跑的 —— 是的话本平台做不了。
    public var requiresCoreEngine: Bool {
        !coreEngine.isEmpty
    }

    /// 不支持的原因（界面与错误文案**共用这一份**，别两处各写一句）。
    public var coreUnsupportedReason: String {
        "该直播源用 `core` 内核（\(coreEngine)），本平台没有对应引擎，取不到清单"
    }

    /// 频道总数（界面摘要用）。
    public var channelCount: Int {
        groups.reduce(0) { $0 + $1.channels.count }
    }

    /// `epg` 逗号串 → 去掉空项后的列表。
    private var epgItems: [String] {
        epg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `ua` 的别名键；只用于解码。
    private enum AliasKeys: String, CodingKey {
        case userAgent
    }
}
