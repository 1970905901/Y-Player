import CatVodCore
import CatVodSource
import Foundation

/// 一次字幕请求：从哪些源里挑（一般是播放结果的 `subs`）+ 用什么请求头。
///
/// 与 ``DanmakuRequest`` 对称：播放页拿到的是各种拼好的结果体，传一个小结构
/// 比让服务去猜「字幕该从哪来」更实在。
public struct SubtitleRequest: Sendable, Equatable {
    /// 候选字幕源（``SpiderResult/subs``）。
    public var sources: [SubtitleSource]
    /// 请求字幕文件时带的头（通常 `HTTPHeaderMerger.merge([site.header, result.header])`）。
    public var headers: [String: String]

    public init(sources: [SubtitleSource], headers: [String: String] = [:]) {
        self.sources = sources
        self.headers = headers
    }

    /// 没有可用源（全是空地址）＝没什么可取，界面据此不触发请求。
    public var isEmpty: Bool {
        SubtitleService.pick(from: sources) == nil
    }
}

/// 字幕在播放页显示的一行状态（M09c）。
///
/// 与 ``DanmakuStatus`` 分开而不是复用：两者的「空」含义不同 ——
/// 弹幕关机/没填地址是**用户的选择**，字幕没有是**站点没给**，文案不该一样。
public enum SubtitleStatus: Equatable {
    /// 不显示（还没请求，或本来就是空的）。
    case idle
    /// 正在下载解析。
    case loading
    /// 站点给了源，但取回来是空的（下到了、没内容）。
    case empty
    /// 取到了：源名 + 条数。
    case loaded(source: String, count: Int)
    /// 失败（网络、格式…）。
    case failed(reason: String)

    /// 状态行文案。
    public var text: String {
        switch self {
        case .idle:
            ""
        case .loading:
            "正在加载字幕…"
        case .empty:
            "字幕：站点没有给出可用字幕"
        case let .loaded(source, count):
            "字幕：\(source) · \(count) 条"
        case let .failed(reason):
            "字幕加载失败：\(reason)"
        }
    }
}
