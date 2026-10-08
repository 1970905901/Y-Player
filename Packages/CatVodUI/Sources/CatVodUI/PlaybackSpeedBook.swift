import CatVodPlayer
import Foundation

/// 播放倍速的存档（`UserDefaults` 键 `yplayer.playbackSpeed`）。
///
/// 上游把倍速存成全局偏好（`SpeedSetting.putPlayback` → `speed_playback`），播放页打开时套用；
/// 本项目同一套做法，但**只存倍速**：长按倍速（`speed_long_press`）与跳过静音（`speed_skip_silence`）
/// 一个是手势、一个是内核能力，本轮不做（见 `M02P15-播放页倍速.md`）。
///
/// 与上游的唯一差别：**非正数当坏存档回默认**。上游会把存档里的 `0` 夹成 `0.1`（几乎等于卡住），
/// 而这种取值两种都无法真正播放 —— 取更好解释的那个，并把差别写在这里。
public enum PlaybackSpeedBook {
    /// 存档键。
    ///
    /// `internal` 而不是 `private`：单测要直接往同一个键写脏值，验证「坏存档 ⇒ 默认」。
    static let defaultsKey = "yplayer.playbackSpeed"

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
}
