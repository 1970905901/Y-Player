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
    /// 可调（M03P13：播放页「长按倍速」滑杆 = 上游 `setupLongPress`，范围见 ``longPressMinimum`` /
    /// ``maximum``、步进见 ``longPressStep``），落盘在 UI 层（`PlaybackSpeedBook`）。
    public static let longPress: Float = 2.0
    /// 长按倍速的下限（上游 `LONG_PRESS_MIN = 2.0`）：比正常速度还慢的「加速」没有意义。
    public static let longPressMinimum: Float = 2.0
    /// 长按倍速滑杆的步进（上游 `LONG_PRESS_STEP = 0.5`）。
    public static let longPressStep: Float = 0.5
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

    /// 夹进长按倍速的区间（上游 `clampLongPress`）：``longPressMinimum`` ... ``maximum``。
    public static func clampLongPress(_ speed: Float) -> Float {
        // 与 ``clamp(_:)`` 同一口径：NaN 会一路传到内核，先挡一道回默认值。
        guard !speed.isNaN else {
            return longPress
        }
        return min(max(speed, longPressMinimum), maximum)
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
