import Foundation
import CatVodCore

/// CatSpider 请求载荷值。
///
/// 字段类型必须与参考实现一致：`page` 是**整数**（`CatSpider.java` 用 `addProperty("page", int)`），
/// 发字符串会导致部分 JS 源分页判断失效。
public enum PayloadValue: Sendable, Hashable, Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    /// 扁平字符串对象（如 `filters`）。
    case object([String: String])
    case array([PayloadValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        }
    }
}

/// 请求载荷编码：键排序以保证可复现（便于快照测试与日志比对）。
public enum CatSpiderPayload {
    public static func encode(_ payload: [String: PayloadValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

/// 响应解包。
///
/// 参考实现 `CatSpider.java#unwrap`：
/// - 顶层是 `{code, data}` 且 `data` 是对象 → 取 `data`；
/// - `data` 是数组 → 包装成 `{list: [...]}`；
/// - 其余原样返回。
public enum CatSpiderResponseDecoder {
    public static func decode(_ data: Data, as type: SpiderResult.Type, path: String) throws -> SpiderResult {
        let normalized = try normalize(data, path: path)
        do {
            return try JSONDecoder().decode(type, from: normalized)
        } catch {
            throw CatVodError.decoding(path: path, reason: "结果体不符合 SpiderResult 协议：\(error)")
        }
    }

    /// 把 `{code,data}` 解包成标准结果体；返回可直接解码的 JSON 数据。
    public static func normalize(_ data: Data, path: String) throws -> Data {
        guard !data.isEmpty else {
            throw CatVodError.decoding(path: path, reason: "响应为空")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // 允许返回“JSON 文本的字符串”这种二次编码形态。
            if let text = String(data: data, encoding: .utf8),
               let nested = text.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: nested, options: [.fragmentsAllowed]) {
                return try rewrite(root, path: path)
            }
            throw CatVodError.decoding(path: path, reason: "响应不是合法 JSON")
        }
        return try rewrite(root, path: path)
    }

    private static func rewrite(_ root: Any, path: String) throws -> Data {
        guard let object = root as? [String: Any] else {
            // 顶层数组：直接当作 list。
            if let array = root as? [Any] {
                return try JSONSerialization.data(withJSONObject: ["list": array])
            }
            throw CatVodError.decoding(path: path, reason: "顶层既不是对象也不是数组")
        }

        guard let data = object["data"] else {
            return try JSONSerialization.data(withJSONObject: object)
        }

        if let nested = data as? [String: Any] {
            return try JSONSerialization.data(withJSONObject: nested)
        }
        if let array = data as? [Any] {
            return try JSONSerialization.data(withJSONObject: ["list": array])
        }
        // `data` 是字符串：保留原对象（可能 msg/code 才是有效载荷）。
        return try JSONSerialization.data(withJSONObject: object)
    }
}
