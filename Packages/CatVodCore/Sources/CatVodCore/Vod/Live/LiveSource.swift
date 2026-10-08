import Foundation

/// 直播源（`SourceConfig.lives` 里的一项）。
///
/// 逐条对齐上游 `bean/Live.java` 的字段与取值语义：
/// - `epg` 是**逗号串**：含 `{` 的项是 EPG **接口**，含 `xml`/`gz` 的项是 XML/GZ 文件（``epgAPI`` / ``epgXML``）；
/// - ``headers()`` = `header` 表 + `ua`/`origin`/`referer`（上游 `getHeaders()`）；
/// - ``pass`` 为 true 时，分组名里的 `_` **不**当作密码分隔符（配合 ``LiveGroup/init(name:pass:)``）；
/// - ``isEmpty`` 等价上游 `isEmpty()`（名字为空）。
///
/// 与上游的差别：`boot`/`selected`/`width`/`tested` 是界面运行期状态，不进模型（界面层自己持有）。
public struct LiveSource: Codable, Sendable, Hashable, Identifiable {
    /// 直播源名（界面下拉与持久化都用它）。
    public var name: String
    /// 直播清单地址（m3u / txt / json）。
    public var url: String
    /// 上游 `type`（协议保留字段）。
    public var type: Int?
    /// 播放器类型（协议保留字段）。
    public var playerType: Int?
    /// Spider 接口（js2p / catspider），非空时清单由 Spider `liveContent` 提供。
    public var api: String
    public var ext: String
    public var jar: String
    public var click: String
    public var logo: String
    /// EPG 逗号串（接口 + XML/GZ 文件）。
    public var epg: String
    public var ua: String
    public var origin: String
    public var referer: String
    /// 节目单时区（协议字段，EPG 阶段用）。
    public var timeZone: String
    /// 上次观看位置（`分组名│频道名│…`，持久化字段）。
    public var keep: String
    public var timeout: Int?
    public var header: [String: String]
    /// 源级时移配置（频道级优先，见 ``LiveCatchup/decide(major:minor:)``）。
    public var catchup: LiveCatchup?
    /// 分组与频道（解析结果）。
    public var groups: [LiveGroup]
    /// 分组名拆分开关（上游字段名就是 `pass`）：true 表示组名里的 `_` 不当密码。
    public var pass: Bool

    public var id: String { name }

    public init(
        name: String = "",
        url: String = "",
        type: Int? = nil,
        playerType: Int? = nil,
        api: String = "",
        ext: String = "",
        jar: String = "",
        click: String = "",
        logo: String = "",
        epg: String = "",
        ua: String = "",
        origin: String = "",
        referer: String = "",
        timeZone: String = "",
        keep: String = "",
        timeout: Int? = nil,
        header: [String: String] = [:],
        catchup: LiveCatchup? = nil,
        groups: [LiveGroup] = [],
        pass: Bool = false
    ) {
        self.name = name
        self.url = url
        self.type = type
        self.playerType = playerType
        self.api = api
        self.ext = ext
        self.jar = jar
        self.click = click
        self.logo = logo
        self.epg = epg
        self.ua = ua
        self.origin = origin
        self.referer = referer
        self.timeZone = timeZone
        self.keep = keep
        self.timeout = timeout
        self.header = header
        self.catchup = catchup
        self.groups = groups
        self.pass = pass
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        url = container.lenientString(.url)
        type = container.lenientValue(.type)
        playerType = container.lenientValue(.playerType)
        api = container.lenientString(.api)
        ext = container.lenientString(.ext)
        jar = container.lenientString(.jar)
        click = container.lenientString(.click)
        logo = container.lenientString(.logo)
        epg = container.lenientString(.epg)
        ua = container.lenientString(.ua)
        origin = container.lenientString(.origin)
        referer = container.lenientString(.referer)
        timeZone = container.lenientString(.timeZone)
        keep = container.lenientString(.keep)
        timeout = container.lenientValue(.timeout)
        header = container.lenientStringMap(.header)
        catchup = container.lenientValue(.catchup)
        groups = container.lenientArray(.groups)
        pass = container.lenientBool(.pass)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case type
        case playerType
        case api
        case ext
        case jar
        case click
        case logo
        case epg
        case ua
        case origin
        case referer
        case timeZone
        case keep
        case timeout
        case header
        case catchup
        case groups
        case pass
    }

    /// 上游 `isEmpty()`。
    public var isEmpty: Bool {
        name.isEmpty
    }

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

    /// EPG **接口**地址（上游 `getEpgApi()`：`epg` 逗号串里含 `{` 的那一项）。
    public var epgAPI: String {
        for item in epgItems where item.contains("{") {
            return item
        }
        return epg
    }

    /// EPG **文件**地址（上游 `getEpgXml()`：含 `xml` 或 `gz` 的项）。
    ///
    /// 说明：上游用 `epg.contains("xml") || epg.contains("gz")` 判断，这里保持一致（大小写敏感）。
    public var epgXML: [String] {
        epgItems.filter { !$0.contains("{") && ($0.contains("xml") || $0.contains("gz")) }
    }

    /// 频道总数（界面摘要用）。
    public var channelCount: Int {
        groups.reduce(0) { $0 + $1.channels.count }
    }

    /// `epg` 逗号串 → 去掉空项后的列表。
    private var epgItems: [String] {
        epg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
