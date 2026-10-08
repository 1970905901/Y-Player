import CatVodCore
import CatVodNet
import Foundation

/// 弹幕的**取用链路**：搜索 → 取第一条候选来源 → 下载文件 → 解析成弹幕行（M08b）。
///
/// 上游这条链前面还有一段「标题候选」（手动标题 → TMDB 解析 → 清洗标题 → AI 兜底），
/// 依赖 TMDB（后置项）；本项目直接拿播放页给的片名 + 集名去搜 —— 够用，且不引入一个后置依赖。
///
/// 「没搜到」与「出错了」分开：前者返回空数组（界面上不该是错误提示），后者抛
/// ``CatVodError``（网络真断了要能看出来）。
public struct DanmakuService: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 搜候选来源；空数组 = 没搜到。
    public func search(api: String, name: String, episode: String) async throws -> [DanmakuSource] {
        guard let request = DanmakuAPI.searchRequest(api: api, name: name, episode: episode) else {
            return []
        }
        let urlRequest = Self.httpRequest(from: request)
        let response = try await transport.send(urlRequest)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: urlRequest.url.absoluteString,
                reason: "弹幕搜索返回 \(response.status)"
            )
        }
        return DanmakuSource.array(from: response.text)
    }

    /// 下载并解析一个来源；文件里的坏行跳过（见 ``DanmakuDocument``）。
    ///
    /// 编码只按 UTF-8 解、失败回落 Latin-1（`HTTPResponse.text` 的既有行为）。
    /// 弹幕文件绝大多数是 UTF-8；GBK 的少数会在文本上出问题 —— 这是已知限制，见 M08b 记录。
    public func lines(from source: DanmakuSource) async throws -> [DanmakuLine] {
        let trimmed = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return []
        }
        let response = try await transport.send(HTTPRequest(url: url))
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: trimmed,
                reason: "弹幕文件返回 \(response.status)"
            )
        }
        return DanmakuDocument.parse(response.text)
    }

    /// 一次到位：搜索 → 第一条候选 → 下载解析；没有候选就返回空数组。
    public func load(api: String, name: String, episode: String) async throws -> [DanmakuLine] {
        let sources = try await search(api: api, name: name, episode: episode)
        guard let first = sources.first else {
            return []
        }
        return try await lines(from: first)
    }

    /// 把 ``DanmakuAPI/SearchRequest`` 翻成传输层请求（表单编码与 `Content-Type` 都在这一处）。
    static func httpRequest(from request: DanmakuAPI.SearchRequest) -> HTTPRequest {
        switch request {
        case let .get(url):
            return HTTPRequest(url: url)
        case let .post(url, fields):
            return HTTPRequest(
                url: url,
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(DanmakuAPI.formEncoded(fields).utf8)
            )
        }
    }
}
