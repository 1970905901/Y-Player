import Foundation

/// 播放倍速（逐条对齐上游 FongMi/TV 的 `setting/SpeedSetting.java`）。
///
/// 上游把倍速做成「滑杆 + 8 个预设 + 长按倍速 + 跳过静音」；本轮只做**倍速本身**，
/// 但范围、步进、预设、夹紧与显示格式**全量对齐**。长按倍速的目标值在 M03P12 接上（``longPress``）；
/// 跳过静音仍未做（要内核支持，见 `M02P15-播放页倍速.md`）。
///
/// | 上游 | 这里 |
/// | --- | --- |
/// | `MIN 0.1` / `MAX 5.0` / `STEP 0.1` | ``minimum`` / ``maximum`` / ``step`` |
/// | `NORMAL 1.0` | ``normal`` |
/// | `PRESETS {0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0}` | ``presets`` |
/// | `clamp(speed) = Math.clamp(speed, MIN, MAX)` | ``clamp(_:)`` |
/// | `format = formatValue + "x"`；`value*10` 是整数就 1 位小数，否则 2 位 | ``format(_:)`` |
public enum SpeedSetting {
    /// 最小倍速（上游 `MIN`）。
    public static let minimum: Float = 0.1
    /// 最大倍速（上游 `MAX`）。
    public static let maximum: Float = 5.0
    /// 滑杆步进（上游 `STEP`）。
    public static let step: Float = 0.1
    /// 正常速度（上游 `NORMAL`）。
    public static let normal: Float = 1.0

    /// 长按临时加速的目标速度（上游 `LONG_PRESS = 2.0`）。
    ///
    /// 上游把这个值做成可调的（`setupLongPress`：2.0–5.0、步进 0.5、存 `speed_long_press`）；
    /// 我们还没有对应的设置界面，先按上游默认值用 —— 要做时再补 `clampLongPress` 与存档（M03P12）。
    public static let longPress: Float = 2.0
    /// 预设档位（上游 `PRESETS`，顺序一致）。
    public static let presets: [Float] = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0]
    /// 浮点比较容差（上游 `EPSILON = 0.001`）。
    private static let epsilon: Float = 0.001

    /// 夹进合法区间（上游 `clamp`）。
    public static func clamp(_ speed: Float) -> Float {
        // NaN 会一路传到内核（上游也不判断），所以先挡一道回正常速度；
        // 正负无穷交给下面的 min/max 自然夹到 5.0 / 0.1。
        guard !speed.isNaN else {
            return normal
        }
        return min(max(speed, minimum), maximum)
    }

    /// 是不是正常速度（UI 用来决定「恢复」按钮是否可用、预设打不打勾）。
    public static func isNormal(_ speed: Float) -> Bool {
        abs(clamp(speed) - normal) < epsilon
    }

    /// 两个倍速是不是同一档（容差比较；UI 给预设打勾用，别拿 `==` 比浮点）。
    public static func isSame(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(clamp(lhs) - clamp(rhs)) < epsilon
    }

    /// 展示文本：`1.0x` / `0.8x` / `1.25x`（上游 `format`）。
    public static func format(_ speed: Float) -> String {
        formatValue(speed) + "x"
    }

    /// 去掉 `x` 的数值文本（上游 `formatValue`）：一位小数够用就一位（`0.8` 而不是 `0.80`）。
    public static func formatValue(_ speed: Float) -> String {
        let value = clamp(speed)
        let scaled = value * 10
        let isSingleDecimal = abs(scaled - scaled.rounded()) < epsilon
        return String(format: isSingleDecimal ? "%.1f" : "%.2f", value)
    }
}
