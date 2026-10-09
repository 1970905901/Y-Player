import CatVodCore
import CatVodNet
import Foundation

/// 字幕取用链：从结果里的字幕源挑一条，下载并解析成 cue。
///
/// 形态与 ``DanmakuService`` 一致（transport 注入、不抛「空结果」这种非错误）：
/// 站点没给字幕不是错误，界面不该弹红。
///
/// **与上游的差别，写清楚免得被当成遗漏**：上游把**全部**字幕源都塞进 `MediaItem`，
/// 由 ExoPlayer 按语言列出让用户选；本项目暂时只取**第一条有地址的**（多语言切换属于渲染层的事，
/// 而渲染由 UI 侧自己的覆盖层画，见 M09f）。所以这里返回的是「挑中的那条 + 它的 cue」，而不是一组。
public struct SubtitleService: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// 一次加载的结果。
    public struct Loaded: Sendable, Equatable {
        public var source: SubtitleSource
        public var cues: [SubtitleCue]
    }

    /// 挑一条可用字幕源：**第一条有地址的**。
    ///
    /// 跳过地址为空的项（有些源会列出语言占位却没有地址）—— 这跟弹幕那边
    /// `DanmakuSource.filter` 丢掉没有 `url` 的项是同一个道理。
    public static func pick(from sources: [SubtitleSource]) -> SubtitleSource? {
        sources.first { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 下载并解析一条字幕源。
    ///
    /// - Parameter headers: 注入的请求头（调用方通常传 `HTTPHeaderMerger.merge([site.header, result.header])`）；
    /// - 文本按 UTF-8 解、失败回退 Latin-1（``HTTPResponse`` 自带），老站点不至于整条读不出来；
    /// - 空响应体返回空数组而不是抛错：**下到了但没内容**，与「下不到」是两件事。
    public func load(from source: SubtitleSource, headers: [String: String] = [:]) async throws -> [SubtitleCue] {
        let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestURL = URL(string: url) else {
            throw CatVodError.decoding(path: "subtitle", reason: "字幕地址不是合法 URL：\(url)")
        }
        let response = try await transport.send(HTTPRequest(url: requestURL, headers: headers))
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: requestURL.absoluteString,
                reason: "字幕下载失败"
            )
        }
        return SubtitleDocument.parse(text: response.text, format: source.format, url: source.url)
    }

    /// 一步到位：挑源 + 下载 + 解析。没有可用源时返回 nil（**不是错误**）。
    public func load(from sources: [SubtitleSource], headers: [String: String] = [:]) async throws -> Loaded? {
        guard let source = Self.pick(from: sources) else {
            return nil
        }
        let cues = try await load(from: source, headers: headers)
        return Loaded(source: source, cues: cues)
    }
}
