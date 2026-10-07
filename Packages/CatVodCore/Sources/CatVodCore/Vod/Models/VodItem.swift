import Foundation

/// 列表/详情条目。
///
/// 字段对照 webhtv `docs/integration/result-vod.md` 的「Vod 字段」表。
/// `vod_play_from` / `vod_play_url` 的解析见 ``PlaylistParser``。
public struct VodItem: Codable, Sendable, Hashable, Identifiable {
    /// 详情 ID。
    public var vodID: String
    /// 标题。
    public var vodName: String
    /// 类型名。
    public var typeName: String
    /// 海报。
    public var vodPic: String
    /// 备注/更新信息。
    public var vodRemarks: String
    /// 年份。
    public var vodYear: String
    /// 地区。
    public var vodArea: String
    /// 导演。
    public var vodDirector: String
    /// 演员。
    public var vodActor: String
    /// 简介。
    public var vodContent: String
    /// 线路名，多个用 `$$$` 分隔。
    public var vodPlayFrom: String
    /// 播放列表，格式见 ``PlaylistParser``。
    public var vodPlayURL: String
    /// `folder` 表示文件夹入口。
    public var vodTag: String
    /// 非空时点击触发 `action()`，不进普通详情。
    public var action: String
    /// TMDB 匹配 payload。
    public var tmdb: AnyJSONValue?
    /// 子分类入口。
    public var cate: AnyJSONValue?
    /// 单条目样式。
    public var style: CardStyle?
    /// 横图快捷样式（`1` 等价 `rect + ratio=1.33`）。
    public var land: Int
    /// 圆形快捷样式（`1` 等价 `oval + ratio=1.0`）。
    public var circle: Int
    /// 图片宽高比。
    public var ratio: Double

    public var id: String { vodID }

    public init(
        vodID: String = "",
        vodName: String = "",
        typeName: String = "",
        vodPic: String = "",
        vodRemarks: String = "",
        vodYear: String = "",
        vodArea: String = "",
        vodDirector: String = "",
        vodActor: String = "",
        vodContent: String = "",
        vodPlayFrom: String = "",
        vodPlayURL: String = "",
        vodTag: String = "",
        action: String = "",
        tmdb: AnyJSONValue? = nil,
        cate: AnyJSONValue? = nil,
        style: CardStyle? = nil,
        land: Int = 0,
        circle: Int = 0,
        ratio: Double = 0
    ) {
        self.vodID = vodID
        self.vodName = vodName
        self.typeName = typeName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodDirector = vodDirector
        self.vodActor = vodActor
        self.vodContent = vodContent
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayURL = vodPlayURL
        self.vodTag = vodTag
        self.action = action
        self.tmdb = tmdb
        self.cate = cate
        self.style = style
        self.land = land
        self.circle = circle
        self.ratio = ratio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vodID = container.lenientString(.vodID)
        vodName = container.lenientString(.vodName)
        typeName = container.lenientString(.typeName)
        vodPic = container.lenientString(.vodPic)
        vodRemarks = container.lenientString(.vodRemarks)
        vodYear = container.lenientString(.vodYear)
        vodArea = container.lenientString(.vodArea)
        vodDirector = container.lenientString(.vodDirector)
        vodActor = container.lenientString(.vodActor)
        vodContent = container.lenientString(.vodContent)
        vodPlayFrom = container.lenientString(.vodPlayFrom)
        vodPlayURL = container.lenientString(.vodPlayURL)
        vodTag = container.lenientString(.vodTag)
        action = container.lenientString(.action)
        tmdb = container.lenientJSON(.tmdb)
        cate = container.lenientJSON(.cate)
        style = container.lenientValue(.style)
        land = container.lenientInt(.land)
        circle = container.lenientInt(.circle)
        ratio = container.lenientDouble(.ratio)
    }

    enum CodingKeys: String, CodingKey {
        case vodID = "vod_id"
        case vodName = "vod_name"
        case typeName = "type_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodDirector = "vod_director"
        case vodActor = "vod_actor"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayURL = "vod_play_url"
        case vodTag = "vod_tag"
        case action
        case tmdb
        case cate
        case style
        case land
        case circle
        case ratio
    }
}

public extension VodItem {
    /// 是否为文件夹入口条目。
    var isFolder: Bool {
        vodTag == "folder"
    }

    /// 是否为需要走 `action()` 的条目。
    var isActionEntry: Bool {
        !action.isEmpty
    }

    /// 条目的有效样式：条目级 > 站点级 > 默认。
    func resolvedStyle(siteStyle: CardStyle?) -> CardStyle {
        CardStyleResolver.resolve(item: style, site: siteStyle)
    }
}
