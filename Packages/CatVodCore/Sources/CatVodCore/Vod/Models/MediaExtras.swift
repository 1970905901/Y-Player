import Foundation

/// DRM 配置。
///
/// 对照 webhtv `docs/integration/player.md` 的「DRM」小节。
/// 平台限制：iOS/macOS 无 Widevine / PlayReady，仅 ClearKey 可自研实现。
public struct DrmConfig: Codable, Sendable, Hashable {
    public enum Scheme: String, Sendable, CaseIterable {
        case widevine
        case playready
        case clearkey
    }

    /// License URL 或 ClearKey JSON。
    public var key: String
    /// `widevine` / `playready` / `clearkey`。
    public var type: String
    /// 是否强制默认 license URL。
    public var forceKey: Bool
    /// license 请求 header。
    public var header: [String: String]

    public init(key: String = "", type: String = "", forceKey: Bool = false, header: [String: String] = [:]) {
        self.key = key
        self.type = type
        self.forceKey = forceKey
        self.header = header
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.lenientString(.key)
        type = container.lenientString(.type)
        forceKey = container.lenientBool(.forceKey)
        header = container.lenientStringMap(.header)
    }

    enum CodingKeys: String, CodingKey {
        case key
        case type
        case forceKey
        case header
    }

    public var scheme: Scheme? {
        Scheme(rawValue: type.lowercased())
    }

    /// 当前平台是否支持该 DRM 方案。
    public var availability: SiteAvailability {
        switch scheme {
        case .clearkey:
            return .available
        case .widevine, .playready:
            return .unavailable(reason: "Apple 平台不支持 \(type)")
        case nil:
            return .unavailable(reason: "未知 DRM 类型：\(type)")
        }
    }
}

/// 字幕源。
public struct SubtitleSource: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    /// 语言标识（如 `zh`、`en`），可能为空。
    public var language: String
    /// 媒体类型（如 `application/x-subrip`）。
    public var format: String

    public var id: String { "\(language)|\(url)" }

    /// 展示名：`name` → `language` → `url` 逐级回落。
    ///
    /// 与 ``DanmakuSource/displayName`` 同一思路，只是字幕多一层「语言」可用 ——
    /// 字幕源常常只给 `zh` / `en` 而不给名字。
    public var displayName: String {
        if !name.isEmpty {
            return name
        }
        return language.isEmpty ? url : language
    }

    public init(name: String = "", url: String = "", language: String = "", format: String = "") {
        self.name = name
        self.url = url
        self.language = language
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = container.lenientString(.language)
        format = container.lenientString(.format)
        let directName = container.lenientString(.name)
        let directURL = container.lenientString(.url)
        if directName.isEmpty || directURL.isEmpty {
            // 部分源使用 label/src 写法。
            let aliases = try decoder.container(keyedBy: AliasKeys.self)
            name = directName.isEmpty ? aliases.lenientString(.label) : directName
            url = directURL.isEmpty ? aliases.lenientString(.src) : directURL
        } else {
            name = directName
            url = directURL
        }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case language
        case format
    }

    /// `name`/`url` 的别名键；只用于解码。
    private enum AliasKeys: String, CodingKey {
        case label
        case src
    }
}
