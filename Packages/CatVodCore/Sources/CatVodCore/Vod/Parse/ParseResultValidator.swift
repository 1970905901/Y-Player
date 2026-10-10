import Foundation

/// 解析结果的校验与提取规则（逐条对齐上游 `ParseJob`）。
///
/// 单独放一个类型的原因：这些是**协议事实**，不是某个执行器的实现细节 ——
/// M5b（`type=1` JSON）与 M5c（Web 嗅探）都用同一套判定；JAR / Python 通道已明确不支持，别再当待办。
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

    /// 解析结果是否**还需要继续解析**（`parse = 1` 或 `jx = 1`）—— 上游 `Result.needParse()`。
    ///
    /// 为 `true` 时交给 ``ParseJobResolver/followUp(parsedURL:headers:context:)`` 再排一次。
    ///
    /// ⚠️ 它与 ``usesParse(resultPlayURL:flag:configFlags:hasDefaultParser:jx:)`` 是**两个不同的判定**
    /// （上游也是两个方法：`needParse()` / `isUseParse()`），别混 —— 这一个只看结果**自称**要不要解析。
    public static func needsFollowUp(_ result: SpiderResult) -> Bool {
        result.requiresParsing
    }

    /// 这次播放**要不要先套默认解析器** —— 上游 `Result.isUseParse()`（M09h）。
    ///
    /// 上游原文：
    /// ```
    /// if (!VodConfig.hasParse()) return false;
    /// return (getPlayUrl().isEmpty() && VodConfig.get().getFlags().contains(getFlag())) || getJx() == 1;
    /// ```
    ///
    /// `flags`（上游叫 **`vipFlags`**）唯一的用途就在这里：配置声明「这些线路要靠解析」。
    /// （上游还把它传给 spider 的 `playerContent(flag, id, vipFlags)`，那是宿主侧的事。）
    ///
    /// 为什么必须与 `needParse()` 分开：那一个是「结果自称要解析」，这一个是「配置认不认这条线路
    /// 需要解析」。混用会两头都错 —— 没被声明过的线路也去套默认解析器，或者把声明过的漏掉。
    ///
    /// - Parameters:
    ///   - resultPlayURL: 结果级 `playUrl`（``SpiderResult/playUrl``）。
    ///   - flag: 本次线路名（协议里的 `flag`）。
    ///   - configFlags: 配置的 `flags`。
    ///   - hasDefaultParser: 配置里有没有默认解析器（`SourceConfig.parse` 非空）。
    ///   - jx: 结果的 `jx`。
    public static func usesParse(
        resultPlayURL: String,
        flag: String,
        configFlags: [String],
        hasDefaultParser: Bool,
        jx: Int
    ) -> Bool {
        // 配置里没有默认解析器 → 没什么可套的。这一道**在 `jx` 判断之前**，与上游顺序一致：
        // 上游 `isUseParse()` 也是先 `hasParse()`，没有默认解析器时连 `jx == 1` 都返回 false。
        guard hasDefaultParser else {
            return false
        }
        // 空线路名不该匹配到任何 flag：`flags: ["", "youku"]` 这种配置下，
        // 不挡这道会把「没有线路名的直链结果」也判成要解析。
        // 空白串不算 flag：`"   "` 会让 `configFlags.contains` 判为相等 ——
        // 但那是「两边都空」，不是匹配上了解析器。用 `isWhitespace` 判定，不引 Foundation。
        let hasVisibleFlag = flag.contains { !$0.isWhitespace }
        let matched = hasVisibleFlag && configFlags.contains(flag)
        return (resultPlayURL.isEmpty && matched) || jx == 1
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
