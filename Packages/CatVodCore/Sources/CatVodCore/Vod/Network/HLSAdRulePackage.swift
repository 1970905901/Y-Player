import Foundation

/// HLS 规则包（JSON，带 `schemaVersion`）。
///
/// 对齐参考实现 `app/src/main/java/com/fongmi/android/tv/bean/HlsRulePackage.java`：
/// **只认 `schemaVersion == 2`**，其余（JSON 坏了、版本不认识）一律当**空包** ——
/// 规则包是「整包替换」的东西，版本对不上就当没有，而不是按认得出的字段凑合用。
public struct HLSAdRulePackage: Codable, Sendable, Hashable {
    /// 认得的版本号（参考实现同样写死 2）。
    public static let supportedSchemaVersion = 2

    public var schemaVersion: Int
    public var packageId: String
    public var version: Int
    public var rules: [HLSAdRule]

    public init(schemaVersion: Int = 0, packageId: String = "", version: Int = 0, rules: [HLSAdRule] = []) {
        self.schemaVersion = schemaVersion
        self.packageId = packageId
        self.version = version
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.lenientInt(.schemaVersion)
        packageId = container.lenientString(.packageId)
        version = container.lenientInt(.version)
        rules = container.lenientArray(.rules)
    }

    /// 空包：解析失败或版本不认识时的返回值（`rules` 为空，`packageId` 为空）。
    public static var empty: HLSAdRulePackage {
        HLSAdRulePackage()
    }

    /// 解析规则包：坏 JSON、版本不认识都返回 ``empty``。
    public static func parse(_ json: String) -> HLSAdRulePackage {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(HLSAdRulePackage.self, from: data),
              value.schemaVersion == supportedSchemaVersion
        else {
            return .empty
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case packageId
        case version
        case rules
    }
}
