import Foundation

/// 弹幕 API 配置（设置 → 播放 → 弹幕 API）。
///
/// 对应参考图：「启用弹幕 API」开关 + `API-1`…`API-4` 四个地址槽位。
/// 这里**只负责把用户填的地址可靠地存下来**（槽位固定 4 个、顺序稳定），
/// 弹幕的请求链与渲染属于 M8，尚未接入 —— 页面会如实写明这一点，不做假开关。
public struct DanmakuAPIConfig: Sendable, Equatable {
    /// 地址槽位数量（参考图固定 4 个：API-1…API-4）。
    public static let slotCount = 4

    /// 是否启用弹幕 API（参考图副标题：开启后将禁用视频源的弹幕功能）。
    public var isEnabled: Bool
    /// 四个槽位的地址；始终 ``slotCount`` 个元素（不足补空串）。
    public private(set) var addresses: [String]

    public init(isEnabled: Bool = false, addresses: [String] = []) {
        self.isEnabled = isEnabled
        self.addresses = Self.normalized(addresses)
    }

    /// 槽位下标（0 起）；越界返回空串，避免界面用 `array[index]` 直接崩。
    public func address(at index: Int) -> String {
        addresses.indices.contains(index) ? addresses[index] : ""
    }

    /// 写入某个槽位（越界忽略）。
    public mutating func setAddress(_ value: String, at index: Int) {
        guard addresses.indices.contains(index) else {
            return
        }
        addresses[index] = value
    }

    /// 已填写的地址（去掉空白项）：用于设置页摘要「已填 2 / 4」。
    public var filledAddresses: [String] {
        addresses.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 把任意长度的数组归一化成 ``slotCount`` 个槽位（多余的截断）。
    public static func normalized(_ raw: [String]) -> [String] {
        var result = Array(raw.prefix(slotCount))
        while result.count < slotCount {
            result.append("")
        }
        return result
    }

    // MARK: - 持久化

    /// 落 `UserDefaults` 的形态：`enabled|地址1|地址2|地址3|地址4`。
    ///
    /// 用竖线拼接而不是 JSON：地址里不会出现竖线（URL 会把 `|` 转义成 `%7C`），
    /// 这样读取时不必处理解码失败的分支。
    public var persistenceValue: String {
        ([isEnabled ? "1" : "0"] + addresses).joined(separator: "|")
    }

    /// 从 `UserDefaults` 的字符串还原；空串或格式不对时回退到「未启用 + 全空」。
    public static func decode(_ raw: String?) -> DanmakuAPIConfig {
        guard let raw, !raw.isEmpty else {
            return DanmakuAPIConfig()
        }
        var parts = raw.components(separatedBy: "|")
        let enabledFlag = parts.isEmpty ? "0" : parts.removeFirst()
        return DanmakuAPIConfig(isEnabled: enabledFlag == "1", addresses: parts)
    }
}
