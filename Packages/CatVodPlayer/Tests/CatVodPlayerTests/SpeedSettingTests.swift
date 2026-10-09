@testable import CatVodPlayer
import Testing

/// 播放倍速：逐条对齐上游 `setting/SpeedSetting.java`（范围、步进、预设、夹紧、显示格式）。
@Suite("播放倍速（对齐上游 SpeedSetting.java）")
struct SpeedSettingTests {
    @Test("常量与预设：范围 / 步进 / 正常值 / 8 个档位")
    func constants() {
        #expect(SpeedSetting.minimum == 0.1)
        #expect(SpeedSetting.maximum == 5.0)
        #expect(SpeedSetting.step == 0.1)
        #expect(SpeedSetting.normal == 1.0)
        #expect(SpeedSetting.presets == [0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0])
        // 每个预设都必须在合法区间里（否则点了会被静默改值）
        let allPresetsClamped = SpeedSetting.presets.allSatisfy { SpeedSetting.clamp($0) == $0 }
        #expect(allPresetsClamped)
    }

    @Test("夹紧：越界、无穷、NaN")
    func clamping() {
        #expect(SpeedSetting.clamp(0.01) == 0.1)
        #expect(SpeedSetting.clamp(-3) == 0.1)
        #expect(SpeedSetting.clamp(9) == 5.0)
        #expect(SpeedSetting.clamp(1.25) == 1.25)
        #expect(SpeedSetting.clamp(.infinity) == 5.0)
        #expect(SpeedSetting.clamp(-.infinity) == 0.1)
        // NaN 交给内核会把播放器带进怪状态（拿不到速度），统一回正常速度
        #expect(SpeedSetting.clamp(.nan) == 1.0)
    }

    @Test("显示格式：一位小数够用就一位，否则两位，末尾带 x")
    func formatting() {
        #expect(SpeedSetting.format(1.0) == "1.0x")
        #expect(SpeedSetting.format(0.8) == "0.8x")
        #expect(SpeedSetting.format(1.2) == "1.2x")
        #expect(SpeedSetting.format(2.0) == "2.0x")
        #expect(SpeedSetting.format(5.0) == "5.0x")
        #expect(SpeedSetting.format(1.25) == "1.25x")
        // 越界先夹紧再显示
        #expect(SpeedSetting.format(0.05) == "0.1x")
        #expect(SpeedSetting.format(9) == "5.0x")
        #expect(SpeedSetting.formatValue(1.5) == "1.5")
        // NaN 不显示成 `nanx`
        #expect(SpeedSetting.format(.nan) == "1.0x")
    }

    @Test("是不是正常速度 / 是不是同一档（容差比较）")
    func comparison() {
        #expect(SpeedSetting.isNormal(1.0))
        #expect(SpeedSetting.isNormal(1.0005))
        #expect(!SpeedSetting.isNormal(1.2))
        #expect(SpeedSetting.isSame(1.2, 1.2))
        #expect(!SpeedSetting.isSame(1.2, 1.5))
        // 都被夹到 0.1，所以算同一档（界面据此给预设打勾）
        #expect(SpeedSetting.isSame(0, 0.05))
    }
}
