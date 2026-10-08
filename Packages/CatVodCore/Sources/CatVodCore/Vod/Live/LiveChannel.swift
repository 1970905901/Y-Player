import Foundation

/// 直播频道。
///
/// 逐条对齐上游 `bean/Channel.java` 的字段与取值语义（含默认值/回落的处理）：
/// - ``epgID``（上游 `getTvgId`）为空时回落 `tvgName`，`tvgName` 再回落频道名 —— 节目单匹配靠它；
/// - ``parse`` 默认 0，语义与点播一致：`0` = 直连，`1` = 需要解析；
/// - ``requestHeaders(fallback:)`` 把 `header` 表与 `ua`/`origin`/`referer` 三个便捷字段合并
///   （与 ``LiveSource/headers()`` 同一套做法，上游 `Live.getHeaders()` 也这么做）。
///
/// 与上游的差别：`show`（界面改名）是运行期字段、不参与 JSON，因此不进模型（界面层自己持有）；
/// DRM/`Epg` 数据同样属播放/节目单阶段，见 `docs/任务记录/M07a-直播模型与清单解析.md`。
public struct LiveChannel: Codable, Sendable, Hashable, Identifiable {
    /// 频道名（同名频道在同一个分组里会被合并 URLs）。
    public var name: String
    /// 播放地址列表（多个线路）。
    public var urls: [String]
    /// 频道号（协议里的 `number`）；解析完会给没有号的频道补 `001`、`002`…
    public var number: String
    public var logo: String
    public var epg: String
    /// 节目单匹配 ID（`tvg-id`）。
    public var tvgID: String
    public var tvgName: String
    public var ua: String
    public var click: String
    public var format: String
    public var origin: String
    public var referer: String
    public var header: [String: String]
    /// `0` 直连 / `1` 需要解析。
    public var parse: Int
    /// 时移（catchup）配置。
    public var catchup: LiveCatchup?

    public var id: String { name }

    /// 构造：解析器只需要「名字」（其余字段随后按需赋值），
    /// 字段多的模型一律走 JSON 解码，避免十几参数的长 init（SwiftLint `function_parameter_count` 会报错）。
    public init(name: String, urls: [String] = [], catchup: LiveCatchup? = nil) {
        self.name = name
        self.urls = urls
        self.catchup = catchup
        number = ""
        logo = ""
        epg = ""
        tvgID = ""
        tvgName = ""
        ua = ""
        click = ""
        format = ""
        origin = ""
        referer = ""
        header = [:]
        parse = 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        urls = container.lenientStringArray(.urls)
        number = container.lenientString(.number)
        logo = container.lenientString(.logo)
        epg = container.lenientString(.epg)
        tvgID = container.lenientString(.tvgID)
        tvgName = container.lenientString(.tvgName)
        ua = container.lenientString(.ua)
        click = container.lenientString(.click)
        format = container.lenientString(.format)
        origin = container.lenientString(.origin)
        referer = container.lenientString(.referer)
        header = container.lenientStringMap(.header)
        parse = container.lenientInt(.parse)
        catchup = container.lenientValue(.catchup)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case urls
        case number
        case logo
        case epg
        case tvgID = "tvgId"
        case tvgName
        case ua
        case click
        case format
        case origin
        case referer
        case header
        case parse
        case catchup
    }

    /// 节目单匹配 ID：`tvgId` 为空回落 `tvgName`，再为空回落频道名（上游 `getTvgId` + `getTvgName`）。
    public var epgID: String {
        if !tvgID.isEmpty {
            return tvgID
        }
        return tvgName.isEmpty ? name : tvgName
    }

    /// 播放要带的 header：`header` 表 + `ua`/`origin`/`referer`（后者覆盖同名）。
    public func requestHeaders(fallback: [String: String] = [:]) -> [String: String] {
        var merged = fallback
        for (key, value) in header where !value.isEmpty {
            merged[key] = value
        }
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

    /// 上游 `isEmpty()`：**名字为空**才算空（地址可以为空 —— 播放时才需要）。
    public var isEmpty: Bool {
        name.isEmpty
    }

    // MARK: - 播放期语义（对齐上游 Channel 的取值方法）

    /// 第 `index` 条线路的地址（上游 `getCurrent()`）。
    ///
    /// 上游在**没有 DRM** 时会把 `地址$线路名` 的 `$` 后半段去掉；DRM 那部分属后续阶段
    /// （见 `docs/任务记录/M07a-直播模型与清单解析.md`），因此这里总是按「无 DRM」处理。
    public func playbackURL(index: Int = 0) -> String {
        guard urls.indices.contains(index) else {
            return ""
        }
        return Self.strippingLineSuffix(urls[index])
    }

    /// 第 `index` 条线路的名字（上游 `getLine()`：`地址$线路名` 的后半段）。
    ///
    /// 返回 `nil` 表示地址里没写线路名，界面按「线路 N」自行命名（上游用资源字符串，属界面职责）。
    public func lineName(index: Int = 0) -> String? {
        guard urls.indices.contains(index) else {
            return nil
        }
        let parts = urls[index].split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else {
            return nil
        }
        return String(parts[1])
    }

    /// 当前地址该不该给时移入口，以及用哪份时移配置（上游 `hasCatchup()`）。
    ///
    /// 逻辑逐条照搬：没有配时移但地址里含 `/PLTV/` 时自动套用内置 PLTV 规则；
    /// 配了 `regex` 就必须命中当前地址；只配了 `source` 则直接可用。
    public func catchupForCurrentURL(index: Int = 0) -> LiveCatchup? {
        var resolved = catchup
        let url = playbackURL(index: index)
        if resolved?.isEmpty ?? true, url.contains("/PLTV/") {
            resolved = .pltv()
        }
        guard let effective = resolved, !effective.isEmpty else {
            return nil
        }
        guard !effective.regex.isEmpty else {
            return effective
        }
        return effective.matches(url: url) ? effective : nil
    }

    /// 上游 `Channel.live(Live)`：把直播源级设置**补进没有自己设置的**频道，并展开 logo / EPG 模板。
    ///
    /// 补的字段与上游一致：`ua` / `click` / `header` / `origin` / `catchup` / `referer`；
    /// 模板展开也照搬上游两条（`Channel.java` 的 `live(Live)`）：
    /// - `logo`：源级 `logo` 含 `{` 且频道自己不是 http 地址时，按 `{id}`/`{name}`/`{logo}` 展开；
    /// - `epg`：源级 `epg` 含 `{` 且频道自己不是 http 地址时，取源级**接口**那一项（``LiveSource/epgAPI``）
    ///   按 `{id}`/`{name}`/`{epg}` 展开 —— 展开后仍是模板（还带 `{date}`），拉取时再按天替换（M07c）。
    public mutating func inherit(from source: LiveSource) {
        if ua.isEmpty, !source.ua.isEmpty {
            ua = source.ua
        }
        if click.isEmpty, !source.click.isEmpty {
            click = source.click
        }
        if header.isEmpty, !source.header.isEmpty {
            header = source.header
        }
        if origin.isEmpty, !source.origin.isEmpty {
            origin = source.origin
        }
        if catchup?.isEmpty ?? true, let inherited = source.catchup, !inherited.isEmpty {
            catchup = inherited
        }
        if referer.isEmpty, !source.referer.isEmpty {
            referer = source.referer
        }
        if source.logo.contains("{"), !logo.hasPrefix("http") {
            logo = expanding(template: source.logo, into: logo)
        }
        if source.epg.contains("{"), !epg.hasPrefix("http") {
            epg = expanding(template: source.epgAPI, into: epg)
        }
    }

    /// 展开源级模板里的 `{id}` / `{name}` / `{logo}` / `{epg}`（上游那两行的参数化写法）。
    ///
    /// `{epg}` 用频道自己的 `epg` 值（模板里常写 `…?ch={epg}`），`{date}` 不在这里替换。
    private func expanding(template: String, into own: String) -> String {
        template
            .replacingOccurrences(of: "{id}", with: epgID)
            .replacingOccurrences(of: "{name}", with: tvgName.isEmpty ? name : tvgName)
            .replacingOccurrences(of: "{logo}", with: own)
            .replacingOccurrences(of: "{epg}", with: own)
    }

    /// 去掉 `地址$线路名` 的 `$` 后半段（上游 `url.split("\\$")[0]`）。
    static func strippingLineSuffix(_ url: String) -> String {
        guard let marker = url.firstIndex(of: "$") else {
            return url
        }
        return String(url[url.startIndex ..< marker])
    }
}
