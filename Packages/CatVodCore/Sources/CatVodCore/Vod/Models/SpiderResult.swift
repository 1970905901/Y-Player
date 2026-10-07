import Foundation

/// Spider / CMS 统一返回体。
///
/// 字段对照 webhtv `docs/integration/result-vod.md` 的「Result 顶层字段」表；
/// 播放地址与解析相关字段的语义见 `docs/integration/player.md`。
public struct SpiderResult: Codable, Sendable, Hashable {
    /// 分类列表（JSON 键为 `class`）。
    public var categories: [VodCategory] = []
    /// 条目列表。
    public var list: [VodItem] = []
    /// 以分类 ID 为键的筛选项。
    public var filters: [String: [VodFilter]] = [:]
    /// 播放地址集合。
    public var url: PlaybackURLs = PlaybackURLs()
    /// 播放或请求 header。
    public var header: [String: String] = [:]
    /// Toast 文本；仅 `code=0` 时生效。
    public var msg: String = ""
    /// 状态码。
    public var code: Int = 0
    /// 弹幕源列表。
    public var danmaku: [DanmakuSource] = []
    /// 字幕列表。
    public var subs: [SubtitleSource] = []
    /// 播放前缀或解析指令（`json:` / `parse:{name}`）。
    public var playUrl: String = ""
    /// 播放器封面。
    public var artwork: String = ""
    /// 解析来源。
    public var jxFrom: String = ""
    /// 当前线路。
    public var flag: String = ""
    /// 播放描述。
    public var desc: String = ""
    /// 歌词。
    public var lrc: String = ""
    /// 媒体 MIME。
    public var format: String = ""
    /// WebView 点击脚本。
    public var click: String = ""
    /// 站点 key。
    public var key: String = ""
    /// 起播位置（毫秒）。
    public var position: Int = 0
    /// 总页数。
    public var pagecount: Int = 0
    /// 解析 WebView 标记（`1` 强制解析）。
    public var parse: Int = 0
    /// 需解析标记（`1` 等同需要解析）。
    public var jx: Int = 0
    /// DRM 配置。
    public var drm: DrmConfig?
    /// 当前页（部分源返回）。
    public var page: Int = 1
    /// 结果总数（部分源返回）。
    public var total: Int = 0

    /// 空结果（所有字段取默认值）。
    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = container.lenientArray(.categories)
        list = container.lenientArray(.list)
        filters = container.lenientValue(.filters) ?? [:]
        url = container.lenientValue(.url) ?? PlaybackURLs()
        header = container.lenientStringMap(.header)
        msg = container.lenientString(.msg)
        code = container.lenientInt(.code)
        danmaku = container.lenientArray(.danmaku)
        subs = container.lenientArray(.subs)
        playUrl = container.lenientString(.playUrl)
        artwork = container.lenientString(.artwork)
        jxFrom = container.lenientString(.jxFrom)
        flag = container.lenientString(.flag)
        desc = container.lenientString(.desc)
        lrc = container.lenientString(.lrc)
        format = container.lenientString(.format)
        click = container.lenientString(.click)
        key = container.lenientString(.key)
        position = max(container.lenientInt(.position), 0)
        pagecount = max(container.lenientInt(.pagecount), 0)
        parse = container.lenientInt(.parse)
        jx = container.lenientInt(.jx)
        drm = container.lenientValue(.drm)
        page = max(container.lenientInt(.page, default: 1), 1)
        total = max(container.lenientInt(.total), 0)
    }

    enum CodingKeys: String, CodingKey {
        case categories = "class"
        case list
        case filters
        case url
        case header
        case msg
        case code
        case danmaku
        case subs
        case playUrl
        case artwork
        case jxFrom
        case flag
        case desc
        case lrc
        case format
        case click
        case key
        case position
        case pagecount
        case parse
        case jx
        case drm
        case page
        case total
    }
}

public extension SpiderResult {
    /// 是否需要走解析流程（`parse=1` 或 `jx=1`）。
    var requiresParsing: Bool {
        parse == 1 || jx == 1
    }

    /// 是否命中上游约定的错误响应（`code != 0` 且带 `msg`）。
    var isErrorResponse: Bool {
        code != 0 && !msg.isEmpty
    }

    /// 是否包含可展示的列表数据。
    var hasList: Bool {
        !list.isEmpty
    }

    /// 是否包含分类数据。
    var hasCategories: Bool {
        !categories.isEmpty
    }

    /// 首条播放地址。
    var primaryPlaybackURL: String? {
        url.selected?.url
    }

    /// 空列表结果（用于分类/搜索无数据时保持协议一致）。
    static func empty(page: Int = 1) -> SpiderResult {
        var result = SpiderResult()
        result.code = 0
        result.page = page
        result.pagecount = 0
        result.total = 0
        return result
    }
}
