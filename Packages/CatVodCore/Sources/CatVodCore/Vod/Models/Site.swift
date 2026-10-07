import Foundation

/// 点播站点。
///
/// 字段与默认值对照 webhtv `docs/integration/vod-site.md` 的字段表；
/// `type` 的取值语义见 ``SiteKind``，运行时归类见 ``Site/spiderRuntimeKind``。
public struct Site: Codable, Sendable, Hashable, Identifiable {
    /// 站点唯一标识；收藏、历史、详情、播放与本地 API 都用它定位站点。
    public var key: String
    /// 展示名。
    public var name: String
    /// 协议/运行时类型（原始数字，未知取值保留）。
    public var type: Int
    /// HTTP API 地址，或 Spider 类名/脚本入口。
    public var api: String
    /// 站点专用 JAR；为空时继承顶层 `spider`。
    public var jar: String
    /// 传给 Spider `init` 的扩展参数；可能是字符串或对象，原样保留。
    public var ext: AnyJSONValue
    /// WebView 解析点击脚本。
    public var click: String
    /// 站点级播放前缀或解析辅助。
    public var playUrl: String
    /// WebHome 首页地址（别名 `home_page` / `webHome` / `web_home` 已在解码时归一化）。
    public var homePage: String
    /// WebHome 浏览器 UI 模式。
    public var chromeMode: String
    /// WebHome chrome 配置（对象或字符串）。
    public var webHomeChrome: AnyJSONValue?
    /// WebHome 站点扩展配置。
    public var extensions: AnyJSONValue?
    /// `1` 隐藏站点。
    public var hide: Int
    /// `1` 作为索引站点参与聚合搜索。
    public var indexs: Int
    /// 播放超时秒数；解码时最小按 1 处理，缺省 15。
    public var timeout: Int
    /// 搜索可用性：`0` 永久禁用、`1` 启用、`2` 临时禁用但允许 App 恢复。
    public var searchable: Int
    /// 换源可用性：`0` 永久禁用、`1` 允许、`2` 临时禁用但允许 App 恢复。
    public var changeable: Int
    /// 是否参与快速搜索（`1` 参与）。
    public var quickSearch: Int
    /// 限定分类列表；空数组表示不限制。
    public var categories: [String]
    /// 站点级请求 header。
    public var header: [String: String]
    /// 卡片样式；不提供时继承默认 `rect`。
    public var style: CardStyle?

    public var id: String { key }

    public init(
        key: String,
        name: String,
        type: Int,
        api: String,
        jar: String = "",
        ext: AnyJSONValue = .null,
        click: String = "",
        playUrl: String = "",
        homePage: String = "",
        chromeMode: String = "",
        webHomeChrome: AnyJSONValue? = nil,
        extensions: AnyJSONValue? = nil,
        hide: Int = 0,
        indexs: Int = 0,
        timeout: Int = 15,
        searchable: Int = 1,
        changeable: Int = 1,
        quickSearch: Int = 1,
        categories: [String] = [],
        header: [String: String] = [:],
        style: CardStyle? = nil
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.jar = jar
        self.ext = ext
        self.click = click
        self.playUrl = playUrl
        self.homePage = homePage
        self.chromeMode = chromeMode
        self.webHomeChrome = webHomeChrome
        self.extensions = extensions
        self.hide = hide
        self.indexs = indexs
        self.timeout = timeout
        self.searchable = searchable
        self.changeable = changeable
        self.quickSearch = quickSearch
        self.categories = categories
        self.header = header
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.lenientString(.key)
        name = container.lenientString(.name)
        type = container.lenientInt(.type)
        api = container.lenientString(.api)
        jar = container.lenientString(.jar)
        ext = container.lenientJSON(.ext) ?? .null
        click = container.lenientString(.click)
        playUrl = container.lenientString(.playUrl)
        chromeMode = container.lenientString(.chromeMode)
        webHomeChrome = container.lenientJSON(.webHomeChrome)
        extensions = container.lenientJSON(.extensions)
        hide = container.lenientInt(.hide)
        indexs = container.lenientInt(.indexs)
        timeout = max(container.lenientInt(.timeout, default: 15), 1)
        searchable = container.lenientInt(.searchable, default: 1)
        changeable = container.lenientInt(.changeable, default: 1)
        quickSearch = container.lenientInt(.quickSearch, default: 1)
        categories = container.lenientStringArray(.categories)
        header = container.lenientStringMap(.header)
        style = container.lenientValue(.style)

        // homePage 的别名：上游同时存在 home_page / webHome / web_home 三种写法。
        let direct = container.lenientString(.homePage)
        if direct.isEmpty {
            let aliases = try decoder.container(keyedBy: HomePageAliasKeys.self)
            homePage = aliases.firstNonEmptyString([.home_page, .webHome, .web_home])
        } else {
            homePage = direct
        }
    }

    enum CodingKeys: String, CodingKey {
        case key
        case name
        case type
        case api
        case jar
        case ext
        case click
        case playUrl
        case homePage
        case chromeMode
        case webHomeChrome
        case extensions
        case hide
        case indexs
        case timeout
        case searchable
        case changeable
        case quickSearch
        case categories
        case header
        case style
    }

    /// `homePage` 的别名键；只用于解码，不参与编码（编码统一写 `homePage`）。
    enum HomePageAliasKeys: String, CodingKey {
        case home_page
        case webHome
        case web_home
    }
}
