import CatVodPlayer
@testable import CatVodUI
import Foundation
import Testing

/// 倍速存档（`UserDefaults` 键 `yplayer.playbackSpeed`）。
///
/// 重点不是「能存能读」（那没什么好测的），而是**坏存档不许把播放器带进怪状态**：
/// 0 / 负数 / NaN 直接回正常速度，而不是变成 0.1 倍速卡死。
@Suite("播放倍速存档")
struct PlaybackSpeedBookTests {
    /// 每个用例一个独立 suite：互不影响，也不会碰真实 App 的 UserDefaults。
    private func defaults() -> UserDefaults {
        let name = "yplayer.tests.speed.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test("没有存档 → 正常速度")
    func emptyArchive() {
        #expect(PlaybackSpeedBook.speed(defaults: defaults()) == SpeedSetting.normal)
    }

    @Test("存了就用存的；写入时先夹紧")
    func roundTrip() {
        let store = defaults()
        PlaybackSpeedBook.save(1.5, defaults: store)
        #expect(PlaybackSpeedBook.speed(defaults: store) == 1.5)

        PlaybackSpeedBook.save(99, defaults: store)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.maximum)

        PlaybackSpeedBook.save(-5, defaults: store)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.minimum)
    }

    @Test("坏存档（0 / 负数 / 非有限）→ 回正常速度")
    func badArchive() {
        let store = defaults()
        let key = PlaybackSpeedBook.defaultsKey

        store.set(0, forKey: key)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.normal)

        store.set(-2.0, forKey: key)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.normal)

        // NaN / inf 写进 plist 不保证原样读回（可能变 0）——两种取值都必须回正常速度
        store.set(Float.nan, forKey: key)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.normal)

        store.set(Float.infinity, forKey: key)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.normal)
    }

    @Test("长按倍速：没有存档 → 上游默认 2.0x")
    func longPressEmpty() {
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: defaults()) == SpeedSetting.longPress)
    }

    @Test("长按倍速：存了就用存的；越界先夹紧（下限 2.0 / 上限 5.0）")
    func longPressRoundTrip() {
        let store = defaults()
        PlaybackSpeedBook.saveLongPressSpeed(3.5, defaults: store)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == 3.5)

        // 比 2.0 还慢的档不存在：写进去就被夹到下限
        PlaybackSpeedBook.saveLongPressSpeed(1.0, defaults: store)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.longPressMinimum)

        PlaybackSpeedBook.saveLongPressSpeed(99, defaults: store)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.maximum)
    }

    @Test("长按倍速：坏存档（0 / 负数 / 非有限）→ 回默认；reset 回 2.0 并写一笔")
    func longPressBadArchive() {
        let store = defaults()
        let key = PlaybackSpeedBook.longPressDefaultsKey

        store.set(0, forKey: key)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.longPress)

        store.set(-3.0, forKey: key)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.longPress)

        store.set(Float.nan, forKey: key)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.longPress)

        PlaybackSpeedBook.saveLongPressSpeed(4.0, defaults: store)
        PlaybackSpeedBook.resetLongPressSpeed(defaults: store)
        #expect(PlaybackSpeedBook.longPressSpeed(defaults: store) == SpeedSetting.longPress)
        #expect(store.object(forKey: key) != nil)
    }

    @Test("reset 回到正常速度，并且确实写了一笔存档")
    func reset() {
        let store = defaults()
        PlaybackSpeedBook.save(3.0, defaults: store)
        PlaybackSpeedBook.reset(defaults: store)
        #expect(PlaybackSpeedBook.speed(defaults: store) == SpeedSetting.normal)
        #expect(store.object(forKey: PlaybackSpeedBook.defaultsKey) != nil)
    }
}
