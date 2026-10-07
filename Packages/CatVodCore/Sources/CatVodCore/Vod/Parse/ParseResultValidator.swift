import Foundation

/// 解析结果的校验与提取规则（逐条对齐上游 `ParseJob`）。
///
/// 单独放一个类型的原因：这些是**协议事实**，不是某个执行器的实现细节 ——
/// M5b（`type=1` JSON）、M5c（Web 嗅探）与后续的 JAR/Python 通道都要用同一套判定。
public enum ParseResultValidator {
    /// `type=1` JSON 解析的响应取址：先 `url`，为空再 `data.url`（上游 `jsonParse`）。
    public static func playURL(fromJSON body: AnyJSONValue) -> String {
        let direct = body["url"]?.stringValue ?? ""
        if !direct.isEmpty {
            return direct
        }
        return body["data"]?["url"]?.stringValue ?? ""
    }

    /// `type=1` 解析成功判定：地址长度 **> 40** 才算成功（上游 `checkResult`）。
    public static func isAcceptable(_ url: String) -> Bool {
        ParserOutcome.isValidJSONResult(url)
    }

    /// 响应里的 header：只认上游 `getHeader(JsonObject)` 认的四个键（大小写不敏感），
    /// 一个都没取到时回落到解析器 / 结果的 header。
    public static func headers(fromJSON body: AnyJSONValue, fallback: [String: String]) -> [String: String] {
        var picked: [String: String] = [:]
        for (key, value) in body.objectValue ?? [:] {
            guard let canonical = canonicalHeaderName(key) else {
                continue
            }
            guard let text = value.stringValue, !text.isEmpty else {
                continue
            }
            picked[canonical] = text
        }
        return picked.isEmpty ? fallback : picked
    }

    /// 解析结果是否**还需要继续解析**（`parse = 1` 或 `jx = 1`）。
    ///
    /// 为 `true` 时交给 ``ParseJobResolver/followUp(parsedURL:headers:context:)`` 再排一次。
    public static func needsFollowUp(_ result: SpiderResult) -> Bool {
        result.requiresParsing
    }

    /// 上游认的四个键 → 标准写法。
    ///
    /// 说明：上游用 `UrlUtil.fixHeader` 归一化（该工具类未随仓库引入），这里只做协议要求的等价映射：
    /// `ua` / `user-agent` / `User-Agent` 都归到 `User-Agent`，`referer` → `Referer`，`cookie` → `Cookie`。
    private static func canonicalHeaderName(_ key: String) -> String? {
        switch key.lowercased() {
        case "user-agent", "ua":
            return "User-Agent"
        case "referer":
            return "Referer"
        case "cookie":
            return "Cookie"
        default:
            return nil
        }
    }
}
