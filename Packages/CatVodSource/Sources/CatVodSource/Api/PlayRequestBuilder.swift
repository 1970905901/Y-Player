import CatVodCore
import CatVodNet
import Foundation

/// 播放请求的来源形态。
public enum PlayRequestSource: Sendable, Hashable {
    /// 类型 0/1/2：`id` 本身就是播放地址或待解析地址。
    case direct
    /// 类型 4：需要以 `play` + `flag` 参数请求站点。
    case http(HTTPRequest)
    /// 类型 3：交给 Spider（JAR/JS/CatSpider HTTP）。
    case spider
}

/// 播放请求。
///
/// 字段与判定逐行对齐参考实现 `SiteApi.playerContent`：
/// - 类型 0/1/2：`url = id`、`flag`、`header = site.header`、`playUrl = site.playUrl`；
///   `parse = (isVideoFormat(id) && playUrl.isEmpty()) ? 0 : 1`；
/// - 类型 4：`play = id`、`flag = flag` 发请求，`parse` 由响应决定；
/// - 类型 3：走 Spider，`parse` 由响应决定。
public struct PlayRequest: Sendable, Hashable {
    public var siteKey: String
    public var flag: String
    public var playID: String
    public var source: PlayRequestSource
    /// 站点级播放前缀（结果级 `playUrl` 为空时生效）。
    public var sitePlayUrl: String
    /// 需要立即解析的标记（仅类型 0/1/2 在本地判定）。
    public var requiresParsing: Bool

    public init(
        siteKey: String,
        flag: String,
        playID: String,
        source: PlayRequestSource,
        sitePlayUrl: String,
        requiresParsing: Bool
    ) {
        self.siteKey = siteKey
        self.flag = flag
        self.playID = playID
        self.source = source
        self.sitePlayUrl = sitePlayUrl
        self.requiresParsing = requiresParsing
    }
}

public enum PlayRequestBuilder {
    /// 构造播放请求。
    public static func makeRequest(site: Site, flag: String, playID: String) throws -> PlayRequest {
        switch site.kind {
        case .xmlApi, .jsonApi, .jsonApiCompat:
            // 直链且没有站点级 playUrl 时直接播放，否则交给解析链。
            let isDirect = MediaFormatSniffer.isVideoFormat(playID) && site.playUrl.isEmpty
            return PlayRequest(
                siteKey: site.key,
                flag: flag,
                playID: playID,
                source: .direct,
                sitePlayUrl: site.playUrl,
                requiresParsing: !isDirect
            )
        case .httpApiBase64Ext:
            return PlayRequest(
                siteKey: site.key,
                flag: flag,
                playID: playID,
                source: .http(try httpPlayRequest(site: site, flag: flag, playID: playID)),
                sitePlayUrl: site.playUrl,
                requiresParsing: true
            )
        case .spider:
            return PlayRequest(
                siteKey: site.key,
                flag: flag,
                playID: playID,
                source: .spider,
                sitePlayUrl: site.playUrl,
                requiresParsing: true
            )
        case nil:
            // 未知类型按 Spider 处理，交给运行时给出明确错误。
            return PlayRequest(
                siteKey: site.key,
                flag: flag,
                playID: playID,
                source: .spider,
                sitePlayUrl: site.playUrl,
                requiresParsing: true
            )
        }
    }

    /// 类型 4 的播放请求：`play` + `flag`（参考实现 SiteApi.playerContent 的 type==4 分支）。
    public static func httpPlayRequest(site: Site, flag: String, playID: String) throws -> HTTPRequest {
        try ApiURLBuilder.makeRequestForPlay(site: site, params: [
            "play": playID,
            "flag": flag
        ])
    }
}
