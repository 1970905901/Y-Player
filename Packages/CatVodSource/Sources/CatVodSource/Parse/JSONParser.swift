import CatVodCore
import CatVodNet
import Foundation

/// `type=1` JSON 解析器：`GET 解析器地址 + webUrl`，读响应里的 `url`（为空再读 `data.url`）。
///
/// 逐条对齐上游 `ParseJob.jsonParse`（webhtv `player/ParseJob.java`）：
/// - 地址：`item.getUrl() + webUrl`；
/// - header：解析器 `ext.header` 优先（上游 `setHeader` 只在它为空时才套结果 header），直接用 ``ParseJob/effectiveHeaders``；
/// - 成功判定：取到的地址**长度 > 40**（``ParseResultValidator/isAcceptable(_:)``）；
/// - 响应 header：只认 UA/Referer/Cookie/ua，一个都没取到时回落到解析器 header；
/// - 超时：`TIMEOUT_PARSE_DEF` = 15 秒（由 ``ParseJob/timeout`` 带下来）。
///
/// 失败一律抛 ``CatVodError``（面向 UI 的统一错误模型），不返回半成品。
public struct JSONParser: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// 执行一个 `type=1` 解析任务。
    public func parse(_ job: ParseJob) async throws -> ParsedPlayback {
        try validate(job)
        let url = try requestURL(for: job)
        let request = HTTPRequest(
            url: url,
            method: .get,
            headers: job.effectiveHeaders,
            timeout: job.timeout
        )
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw CatVodError.network(
                status: response.status,
                url: url.absoluteString,
                reason: "解析器「\(displayName(job))」返回非 2xx"
            )
        }

        let body = try decode(response: response, job: job)
        let playURL = ParseResultValidator.playURL(fromJSON: body)
        guard !playURL.isEmpty else {
            throw CatVodError.parseFailed(
                flag: job.flag,
                reason: "解析器「\(displayName(job))」没有返回播放地址（`url` 与 `data.url` 都是空的）"
            )
        }
        guard ParseResultValidator.isAcceptable(playURL) else {
            throw CatVodError.parseFailed(
                flag: job.flag,
                reason: "解析地址过短（\(playURL.count) 字符 ≤ 40），按协议判为失败"
            )
        }
        return ParsedPlayback(
            url: playURL,
            headers: ParseResultValidator.headers(fromJSON: body, fallback: job.effectiveHeaders),
            from: job.parser.name
        )
    }

    // MARK: - 内部

    /// 只接受**可用**的 `type=1` 解析器。
    private func validate(_ job: ParseJob) throws {
        guard job.availability.isAvailable else {
            throw CatVodError.unsupported(
                feature: "解析器「\(displayName(job))」",
                reason: job.availability.reason ?? "当前平台不可用"
            )
        }
        guard job.kind == .json else {
            throw CatVodError.unsupported(
                feature: "type=\(job.parser.type) 解析",
                reason: "JSONParser 只执行 type=1（JSON）解析器；type=0 的 Web 嗅探属 M5c"
            )
        }
    }

    /// 请求地址 = 解析器地址 + 待解析地址（上游 `item.getUrl() + webUrl`）。
    private func requestURL(for job: ParseJob) throws -> URL {
        let text = job.parser.url + job.webURL
        guard let url = URL(string: text) else {
            throw CatVodError.parseFailed(flag: job.flag, reason: "解析地址无法构造 URL：\(text.prefix(120))")
        }
        return url
    }

    /// 响应体必须是 JSON 对象；否则明确报「不是合法 JSON」并把开头一段带出来（便于对着源排查）。
    private func decode(response: HTTPResponse, job: ParseJob) throws -> AnyJSONValue {
        do {
            return try JSONDecoder().decode(AnyJSONValue.self, from: response.body)
        } catch {
            throw CatVodError.decoding(
                path: "parse.\(displayName(job))",
                reason: "响应不是合法 JSON：\(response.text.prefix(120))"
            )
        }
    }

    private func displayName(_ job: ParseJob) -> String {
        job.parser.name.isEmpty ? "type=\(job.parser.type)" : job.parser.name
    }
}
