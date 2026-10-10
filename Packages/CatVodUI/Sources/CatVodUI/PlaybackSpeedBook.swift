import CatVodPlayer
import Foundation

/// 播放倍速的存档（`UserDefaults` 键 `yplayer.playbackSpeed` / `yplayer.playbackLongPressSpeed`）。
///
/// 上游把倍速存成全局偏好（`SpeedSetting.putPlayback` → `speed_playback`），播放页打开时套用；
/// 长按倍速（上游 `speed_long_press`）在 M03P13 接上 —— 上游把它们放在同一个 `SpeedSetting` 里，
/// 这里也放在同一个存档类型里。跳过静音（`speed_skip_silence`）仍未做：要内核支持。
///
/// 与上游的唯一差别：**非正数当坏存档回默认**。上游会把存档里的 `0` 夹成 `0.1`（几乎等于卡住），
/// 而这种取值两种都无法真正播放 —— 取更好解释的那个，并把差别写在这里。
public enum PlaybackSpeedBook {
    /// 存档键。
    ///
    /// `internal` 而不是 `private`：单测要直接往同一个键写脏值，验证「坏存档 ⇒ 默认」。
    static let defaultsKey = "yplayer.playbackSpeed"
    /// 长按倍速的存档键（M03P13）。
    static let longPressDefaultsKey = "yplayer.playbackLongPressSpeed"

    /// 读取（没有存档 / 坏存档 → ``SpeedSetting/normal``）。
    public static func speed(defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: defaultsKey) != nil else {
            return SpeedSetting.normal
        }
        let value = defaults.float(forKey: defaultsKey)
        guard value.isFinite, value > 0 else {
            return SpeedSetting.normal
        }
        return SpeedSetting.clamp(value)
    }

    /// 写入（先夹紧）。
    public static func save(_ speed: Float, defaults: UserDefaults = .standard) {
        defaults.set(SpeedSetting.clamp(speed), forKey: defaultsKey)
    }

    /// 回到正常速度。
    public static func reset(defaults: UserDefaults = .standard) {
        save(SpeedSetting.normal, defaults: defaults)
    }

    /// 读长按倍速（没有存档 / 坏存档 → ``SpeedSetting/longPress``）。
    ///
    /// 坏存档的口径与倍速一致：**非正数 / 非有限值当坏存档回默认**；
    /// 合法的越界值（比如存档里是个 1.0）走 ``SpeedSetting/clampLongPress(_:)`` 夹到 2.0（上游同）。
    public static func longPressSpeed(defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: longPressDefaultsKey) != nil else {
            return SpeedSetting.longPress
        }
        let value = defaults.float(forKey: longPressDefaultsKey)
        guard value.isFinite, value > 0 else {
            return SpeedSetting.longPress
        }
        return SpeedSetting.clampLongPress(value)
    }

    /// 写长按倍速（先夹紧）。
    public static func saveLongPressSpeed(_ speed: Float, defaults: UserDefaults = .standard) {
        defaults.set(SpeedSetting.clampLongPress(speed), forKey: longPressDefaultsKey)
    }

    /// 长按倍速回到默认（上游「重置」里的那一半）。
    public static func resetLongPressSpeed(defaults: UserDefaults = .standard) {
        saveLongPressSpeed(SpeedSetting.longPress, defaults: defaults)
    }
}
