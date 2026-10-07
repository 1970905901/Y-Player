import Foundation

/// 分类。
///
/// 字段对照 webhtv `docs/integration/result-vod.md` 的「Class / Filter」表。
/// 兼容别名：`type_id` ↔ `id`，`type_name` ↔ `name`。
public struct VodCategory: Codable, Sendable, Hashable, Identifiable {
    /// 分类 ID。
    public var typeID: String
    /// 分类名。
    public var typeName: String
    /// `1` 时作为文件夹/子分类入口处理。
    public var typeFlag: String
    /// 内联筛选。
    public var filters: [VodFilter]
    /// 横图快捷样式。
    public var land: Int
    /// 圆形快捷样式。
    public var circle: Int
    /// 图片宽高比。
    public var ratio: Double

    public var id: String { typeID }

    public init(
        typeID: String = "",
        typeName: String = "",
        typeFlag: String = "",
        filters: [VodFilter] = [],
        land: Int = 0,
        circle: Int = 0,
        ratio: Double = 0
    ) {
        self.typeID = typeID
        self.typeName = typeName
        self.typeFlag = typeFlag
        self.filters = filters
        self.land = land
        self.circle = circle
        self.ratio = ratio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directID = container.lenientString(.typeID)
        let directName = container.lenientString(.typeName)
        if directID.isEmpty || directName.isEmpty {
            // 上游同时存在 type_id/id 与 type_name/name 两套写法。
            let aliases = try decoder.container(keyedBy: AliasKeys.self)
            typeID = directID.isEmpty ? aliases.lenientString(.id) : directID
            typeName = directName.isEmpty ? aliases.lenientString(.name) : directName
        } else {
            typeID = directID
            typeName = directName
        }
        typeFlag = container.lenientString(.typeFlag)
        filters = container.lenientArray(.filters)
        land = container.lenientInt(.land)
        circle = container.lenientInt(.circle)
        ratio = container.lenientDouble(.ratio)
    }

    enum CodingKeys: String, CodingKey {
        case typeID = "type_id"
        case typeName = "type_name"
        case typeFlag = "type_flag"
        case filters
        case land
        case circle
        case ratio
    }

    /// `type_id` / `type_name` 的别名键；只用于解码。
    private enum AliasKeys: String, CodingKey {
        case id
        case name
    }
}

/// 分类筛选。
public struct VodFilter: Codable, Sendable, Hashable, Identifiable {
    /// 筛选参数名，放入 `extend`。
    public var key: String
    /// 显示名。
    public var name: String
    /// 初始值。
    public var initialValue: String
    /// 可选值列表。
    public var values: [VodFilterValue]

    public var id: String { key }

    public init(
        key: String = "",
        name: String = "",
        initialValue: String = "",
        values: [VodFilterValue] = []
    ) {
        self.key = key
        self.name = name
        self.initialValue = initialValue
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.lenientString(.key)
        name = container.lenientString(.name)
        initialValue = container.lenientString(.initialValue)
        values = container.lenientArray(.values)
    }

    // 键名与模型属性名不同：用自定义 raw value 直接映射，避免别名 case 与属性不匹配。
    enum CodingKeys: String, CodingKey {
        case key
        case name
        case initialValue = "init"
        case values = "value"
    }

    /// 初始选中下标（找不到时返回 0）。
    public var initialIndex: Int {
        values.firstIndex { $0.value == initialValue } ?? 0
    }
}

/// 筛选可选值：`n` 显示名，`v` 提交值。
public struct VodFilterValue: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var value: String

    public var id: String { value }

    public init(name: String = "", value: String = "") {
        self.name = name
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenientString(.name)
        value = container.lenientString(.value)
    }

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case value = "v"
    }
}
