import Foundation

// MARK: - 宽松解码辅助
//
// 上游字段类型不稳定（`ext` 是字符串或对象、`searchable` 是数字或字符串、`ratio` 是小数或字符串…）。
// 这里提供**不抛错**的读取方法：键缺失、类型不符、值为 null 都退回默认值，
// 保证「一处类型不符」不会让整份配置解码失败（依据 webhtv docs/integration/configuration.md 的校验清单）。
//
// 设计取舍：模型一律手写 `init(from:)` 使用这些方法，`encode(to:)` 交给编译器合成。
// 不使用 property wrapper：合成解码对“键缺失”的降级行为依赖编译器实现细节，风险不可控。

public extension KeyedDecodingContainer {
    /// 读取任意 JSON 值；键缺失或解码失败返回 nil。
    func lenientJSON(_ key: Key) -> AnyJSONValue? {
        try? decodeIfPresent(AnyJSONValue.self, forKey: key)
    }

    /// 读取字符串；数字与布尔会被归一化（`1` → `"1"`，`true` → `"1"`）。
    func lenientString(_ key: Key, default defaultValue: String = "") -> String {
        lenientJSON(key)?.stringValue ?? defaultValue
    }

    /// 读取整数；兼容 `"1"`、`1.0`、`true`。
    func lenientInt(_ key: Key, default defaultValue: Int = 0) -> Int {
        lenientJSON(key)?.intValue ?? defaultValue
    }

    /// 读取小数；兼容字符串数字。
    func lenientDouble(_ key: Key, default defaultValue: Double = 0) -> Double {
        lenientJSON(key)?.doubleValue ?? defaultValue
    }

    /// 读取布尔；`1`/`"1"`/`"true"` 均为真。
    func lenientBool(_ key: Key, default defaultValue: Bool = false) -> Bool {
        lenientJSON(key)?.boolValue ?? defaultValue
    }

    /// 读取字符串数组；单值包装为单元素数组，null 为空数组，非字符串项被忽略。
    func lenientStringArray(_ key: Key) -> [String] {
        lenientJSON(key)?.stringArrayValue ?? []
    }

    /// 读取字符串字典（如 `header`）；数值型 value 会被归一化。
    func lenientStringMap(_ key: Key) -> [String: String] {
        guard let object = lenientJSON(key)?.objectValue else { return [:] }
        return object.compactMapValues(\.stringValue)
    }

    /// 读取具体类型；失败返回 nil（例如嵌套的 `style`、`ext` 结构体）。
    func lenientValue<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// 按顺序取第一个非空字符串（键缺失/空串都跳过）。
    func firstNonEmptyString(_ keys: [Key]) -> String {
        for key in keys {
            let value = lenientString(key)
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

/// 单值宽松转换（供非容器场景使用）。
public enum LenientCoercion {
    public static func string(_ value: AnyJSONValue?) -> String {
        value?.stringValue ?? ""
    }

    public static func int(_ value: AnyJSONValue?) -> Int {
        value?.intValue ?? 0
    }

    public static func double(_ value: AnyJSONValue?) -> Double {
        value?.doubleValue ?? 0
    }

    public static func bool(_ value: AnyJSONValue?) -> Bool {
        value?.boolValue ?? false
    }
}
