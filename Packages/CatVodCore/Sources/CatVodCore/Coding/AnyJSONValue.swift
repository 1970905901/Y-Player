import Foundation

/// 上游配置中类型不稳定的 JSON 值容器。
///
/// 猫源/TVBox 配置里同一个字段可能是字符串、数组或对象（典型：`ext`、`url`、`styles`），
/// 用枚举统一承接，避免为每个变体写一套 `Codable`，也避免一处类型不符导致整份配置解码失败。
public enum AnyJSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyJSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public extension AnyJSONValue {
    /// 字符串视图：数字与布尔会被转换，对象/数组返回 `nil`。
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return Self.format(value)
        case .bool(let value): return value ? "1" : "0"
        case .null, .array, .object: return nil
        }
    }

    /// 整数视图：兼容 `"1"`、`1.0`、`true`。
    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value) ?? Double(value).map(Int.init)
        case .bool(let value): return value ? 1 : 0
        case .null, .array, .object: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        case .null, .array, .object: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["1", "true", "yes", "on"].contains(value.lowercased())
        case .null, .array, .object: return nil
        }
    }

    var arrayValue: [AnyJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: AnyJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// 取键值，兼容对象内数字键（部分源用 `0`/`1` 做下标）。
    subscript(key: String) -> AnyJSONValue? {
        objectValue?[key]
    }

    /// 字符串数组视图：数组逐项归一化，单值包装为单元素数组，`null` 为空数组。
    var stringArrayValue: [String] {
        switch self {
        case .array(let values): return values.compactMap(\.stringValue)
        case .null: return []
        case .object: return []
        default: return stringValue.map { [$0] } ?? []
        }
    }

    /// 归一化数字文本：整数不显示 `.0`，小数保留有效位。
    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
