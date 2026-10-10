@testable import CatVodUI
import SwiftUI
import Testing

/// 弹幕显示配置的**带夹紧绑定**与「恢复默认」（M03P24）。
///
/// 为什么值得测：这是设置页与播放页快捷面板共用的唯一一条写回路径 ——
/// 「越界被按回范围」「恢复默认不动总开关」这两条要是只靠界面控件守规矩，换个入口就得重来一遍。
@Suite("弹幕显示：共用的绑定与恢复默认")
struct DanmakuDisplayBindingsTests {
    /// 一份可写的本地配置 + 指向它的绑定（与真实用法同形：绑定两端落在同一份配置上）。
    private func makeBindings(
        _ initial: DanmakuDisplayConfig
    ) -> (fields: DanmakuDisplayBindings, read: () -> DanmakuDisplayConfig) {
        final class Box {
            var config: DanmakuDisplayConfig

            init(_ config: DanmakuDisplayConfig) {
                self.config = config
            }
        }
        let box = Box(initial)
        let binding = Binding(
            get: { box.config },
            set: { box.config = $0 }
        )
        return (DanmakuDisplayBindings(config: binding), { box.config })
    }

    @Test("写回时再夹一次：字号 / 透明度越界都被按回范围")
    func clampsOnWrite() {
        let (fields, read) = makeBindings(DanmakuDisplayConfig(fontScale: 0.5, opacity: 0.1))

        fields.fontScale.wrappedValue = 99
        #expect(read().fontScale == DanmakuDisplayConfig.fontScaleRange.upperBound)
        fields.fontScale.wrappedValue = 0.01
        #expect(read().fontScale == DanmakuDisplayConfig.fontScaleRange.lowerBound)

        fields.opacity.wrappedValue = 5
        #expect(read().opacity == DanmakuDisplayConfig.opacityRange.upperBound)
        fields.opacity.wrappedValue = 0
        #expect(read().opacity == DanmakuDisplayConfig.opacityRange.lowerBound)
    }

    @Test("速度 / 区域 / 显示原样透传（这几项没有可夹的范围）")
    func passesThrough() {
        let (fields, read) = makeBindings(DanmakuDisplayConfig(speed: .fast, area: .quarter, isVisible: false))

        fields.speed.wrappedValue = .slow
        fields.area.wrappedValue = .full
        fields.isVisible.wrappedValue = true

        #expect(read().speed == .slow)
        #expect(read().area == .full)
        #expect(read().isVisible)
    }

    @Test("恢复默认：四项回出厂值，总开关不动（上游分页恢复同款）")
    func resetKeepsVisibility() {
        let (fields, read) = makeBindings(
            DanmakuDisplayConfig(fontScale: 1.6, opacity: 1, speed: .slow, area: .quarter, isVisible: false)
        )

        fields.reset()

        let defaults = DanmakuDisplayConfig()
        #expect(read().fontScale == defaults.fontScale)
        #expect(read().opacity == defaults.opacity)
        #expect(read().speed == defaults.speed)
        #expect(read().area == defaults.area)
        // 用户关着弹幕，点「恢复默认」不该把它打开。
        #expect(read().isVisible == false)
    }
}
