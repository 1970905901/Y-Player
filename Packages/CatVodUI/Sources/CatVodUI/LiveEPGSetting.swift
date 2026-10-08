import CatVodCore
import Foundation

/// 直播 EPG 地址的本地覆盖**与历史**（上游 `setting/LiveEpgSetting.java`：
/// `live_epg_url` + `live_epg_history`，历史上限 20）。
///
/// 三处与上游一致：
/// - 地址是**全局一份**（对所有直播源生效），不是每个源各一份；
/// - 历史最近用的排最前、去重、封顶 20 条；
/// - 删历史里「正在用的那一条」时，一并把覆盖清掉（上游 `removeHistory` 就是这么做的）。
///
/// 这个类型只管存取与归一化；「覆盖怎么生效」在 CatVodCore 的 ``LiveEPGOverride`` 里。
public struct LiveEPGSetting: Sendable, Hashable, Codable {
    /// 历史上限（上游 `MAX_HISTORY = 20`）。
    public static let historyLimit = 20

    /// 当前覆盖地址（空 = 用直播源自己的）。
    public var url: String
    /// 最近用过的地址，最近在最前。
    public var history: [String]

    public init(url: String = "", history: [String] = []) {
        self.url = Self.normalized(url)
        self.history = Self.normalizedHistory(history)
    }

    /// 覆盖生效中。
    public var isActive: Bool {
        !url.isEmpty
    }

    // MARK: - 纯变换

    /// 换一个新地址：空串 = **清除覆盖**（历史不动），非空 = 覆盖 + 记进历史（去重置顶、封顶）。
    public func using(_ value: String) -> LiveEPGSetting {
        let trimmed = Self.normalized(value)
        guard !trimmed.isEmpty else {
            return LiveEPGSetting(url: "", history: history)
        }
        var updated = history.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        return LiveEPGSetting(url: trimmed, history: updated)
    }

    /// 从历史里删一条；删的正好是**当前在用的**那一条时，覆盖也一并清掉（上游 `removeHistory`）。
    public func removing(_ value: String) -> LiveEPGSetting {
        let trimmed = Self.normalized(value)
        guard !trimmed.isEmpty else {
            return self
        }
        return LiveEPGSetting(url: trimmed == url ? "" : url, history: history.filter { $0 != trimmed })
    }

    /// 清空历史（不动当前覆盖；上游 `clearHistory`）。
    public func clearingHistory() -> LiveEPGSetting {
        LiveEPGSetting(url: url, history: [])
    }

    // MARK: - 持久化

    /// 落 `UserDefaults` 的形态：JSON（`url` + `history`）。
    public var persistenceValue: String {
        guard let data = try? JSONEncoder().encode(self) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 读存档：**坏数据当默认**（覆盖坏了不该让直播页打不开），顺带再归一化一次。
    public static func decode(_ raw: String?) -> LiveEPGSetting {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return LiveEPGSetting()
        }
        guard let stored = try? JSONDecoder().decode(LiveEPGSetting.self, from: data) else {
            return LiveEPGSetting()
        }
        return LiveEPGSetting(url: stored.url, history: stored.history)
    }

    /// 去首尾空白（上游 `normalize`）。
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 历史归一化：去空白项、去重（保留最先出现的）、截断到 ``historyLimit``。
    static func normalizedHistory(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let trimmed = normalized(value)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return Array(result.prefix(historyLimit))
    }
}
