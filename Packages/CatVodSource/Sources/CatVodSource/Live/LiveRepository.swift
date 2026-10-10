import CatVodCore
import CatVodNet
import Foundation

/// 直播源加载：取清单文本 → 交给 ``LivePlaylistParser`` → 得到带分组频道的 ``LiveSource``。
///
/// 对照上游 `api/LiveApi.java` 的取文本部分（`LiveParser.getText`）：
/// - `api`/`jar` 非空时清单由 Spider 提供（`spider.liveContent(url)`）；本项目 Spider 通道尚未接，
///   因此这里**明确报错**（`unsupported`）而不是静默返回空清单；
/// - 其余按普通 `GET`，带上源级 ``LiveSource/headers()``（`header` 表 + `ua`/`origin`/`referer`）；
/// - 非 2xx、拿不到文本一律抛 ``CatVodError`` 并带上可读原因。
///
/// 超时：`LiveSource.timeout` 按**秒**（上游字段注释即「播放超时秒数」，解码时已保证 ≥ 1）。
public struct LiveRepository: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 拉取并解析一个直播源。
    ///
    /// `groups` 非空时直接返回 —— 与上游 `LiveParser.start` 的短路一致（已经解析过就不重复拉取）。
    public func load(_ source: LiveSource) async throws -> LiveSource {
        // 内核注入源（`core`，如 tvbus）：本平台没有对应引擎，明确拒绝并说清，
        // 不去按普通清单拉一次再抛一个看不懂的错（M20P1）。
        if source.requiresCoreEngine {
            throw CatVodError.unsupported(feature: "直播源「\(source.name)」", reason: source.coreUnsupportedReason)
        }
        guard source.groups.isEmpty else {
            return source
        }
        let text = try await fetchText(source)
        return LivePlaylistParser().parse(text, into: source)
    }

    /// 只要清单文本（便于单测、缓存与诊断）。
    public func fetchText(_ source: LiveSource) async throws -> String {
        guard source.api.isEmpty, source.jar.isEmpty else {
            throw CatVodError.unsupported(
                feature: "直播源「\(source.name)」",
                reason: "清单由 Spider 提供（api/jar 非空），本项目尚未接 Spider 通道"
            )
        }
        // 注意：`URL(string:)` 对 `"not a url"` 这种文本也返回非 nil，必须自己检查 scheme/host
        // （M06c 的 `HLSPlaylistRewriter.resolve` 被这条坑过一次）。
        guard let url = URL(string: source.url), url.scheme != nil, url.host != nil else {
            throw CatVodError.parseFailed(
                flag: source.name,
                reason: "直播源地址无法构造 URL：\(source.url.prefix(120))"
            )
        }
        let request = HTTPRequest(
            url: url,
            method: .get,
            headers: source.headers(),
            timeout: TimeInterval(max(source.timeout, 1))
        )
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: source.url,
                reason: "直播源「\(source.name)」返回非 2xx"
            )
        }
        return response.text
    }
}
