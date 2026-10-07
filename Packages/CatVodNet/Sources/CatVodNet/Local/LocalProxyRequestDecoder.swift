import CatVodCore
import FlyingFox
import Foundation

/// `/proxy` 请求解析：把本机请求还原成「目标地址 + 要注入的 header + 上游方法」。
///
/// 支持两种形态：
/// 1. `GET|HEAD /proxy?url=<percent-encoded>&h=<base64(JSON)>`（播放器用；可再加 `m=POST` 指定上游方法，
///    此时请求体会被原样转发给上游）；
/// 2. `POST /proxy`，请求体 `{"url": "…", "headers": {…}, "method": "GET"}`（header 很多或含特殊字符时更省事）。
///
/// 未识别的请求（缺 `url`、表单不是合法 JSON、方法不支持）返回 nil，由调用方给出 400。
public enum LocalProxyRequestDecoder {
    /// 解析结果。
    public static func decode(
        _ request: FlyingFox.HTTPRequest,
        defaultTimeout: TimeInterval = 30
    ) async throws -> LocalProxyForwardRequest? {
        var target = request.query["url"]
        var headers = LocalProxyURLBuilder.decodeHeaders(request.query["h"])
        var method = upstreamMethod(request.query["m"])
        var upstreamBody: Data?

        if target == nil, request.method == .POST {
            guard let envelope = try? await Self.payload(from: request) else {
                return nil
            }
            target = envelope.url
            for (key, value) in envelope.headers ?? [:] {
                headers[key] = value
            }
            method = upstreamMethod(envelope.method)
        } else if method != .get {
            upstreamBody = try? await request.bodyData
        }

        guard let target, !target.isEmpty, let url = URL(string: target) else {
            return nil
        }
        let client = clientHeaders(from: request)
        return LocalProxyForwardRequest(
            url: url,
            method: method,
            headers: ProxyForwardingPolicy.upstreamRequestHeaders(client: client, injected: headers),
            body: upstreamBody,
            timeout: defaultTimeout
        )
    }

    /// `POST /proxy` 的请求体。
    private struct Payload: Decodable {
        var url: String?
        var headers: [String: String]?
        var method: String?
    }

    private static func payload(from request: FlyingFox.HTTPRequest) async throws -> Payload {
        let data = try await request.bodyData
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    /// 上游方法：只有明确写了 `POST` 才会用 POST，其余一律 GET（播放场景绝大多数是 GET）。
    private static func upstreamMethod(_ value: String?) -> HTTPRequest.Method {
        value?.uppercased() == "POST" ? .post : .get
    }

    /// 把本机请求带过来的 header 取出来（FlyingFox 的 header 名大小写不敏感，这里统一成标准写法）。
    private static func clientHeaders(from request: FlyingFox.HTTPRequest) -> [String: String] {
        var client: [String: String] = [:]
        for (key, value) in request.headers {
            client[key.rawValue] = value
        }
        return client
    }
}
