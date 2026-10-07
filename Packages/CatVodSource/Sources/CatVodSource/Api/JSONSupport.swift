import CatVodCore
import Foundation

/// JSON 序列化辅助（保持键顺序稳定，便于日志与测试比对）。
public enum JSONSupport {
    /// 把可编码值转成 JSON 文本；键排序。
    public static func string(from value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatVodError.decoding(path: "JSONSupport", reason: "无法编码为 UTF-8 文本")
        }
        return text
    }

    /// 把 `AnyJSONValue` 转成 JSON 文本。
    ///
    /// 说明：`AnyJSONValue` 已满足 `Encodable`，直接走上面的泛型重载即可；
    /// 若在这里再写一个同功能重载会导致无限递归。
    public static func string(fromJSONValue value: AnyJSONValue) throws -> String {
        try string(from: value as AnyJSONValue)
    }

    /// 宽松编码：失败时退回空对象文本，避免因 `ext` 异常导致请求无法发出。
    public static func lenientString(from value: some Encodable) -> String {
        (try? string(from: value)) ?? "{}"
    }
}

/// URL 安全的 Base64（类型 4 的 `ext` 参数使用）。
///
/// 对应参考实现的 `Util.base64(json, Util.URL_SAFE)`：使用 `-`/`_` 替换 `+`/`/`，并去掉填充。
public enum Base64URL {
    public static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> String? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
