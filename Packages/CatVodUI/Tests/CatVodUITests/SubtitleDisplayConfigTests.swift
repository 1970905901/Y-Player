@testable import CatVodUI
import Testing

@Suite("字幕显示设置：默认值 / 持久化 / 上屏换算")
struct SubtitleDisplayConfigTests {
    @Test("默认值就是 M09f 的行为：不碰设置 = 屏上什么都不变")
    func defaultsMatchBaseline() {
        let config = SubtitleDisplayConfig()
        #expect(config.isVisible)
        #expect(config.fontScale == 1)
        #expect(config.position == .low)
        #expect(config.background == .translucent)

        // 与渲染层自己的默认值逐项相等 —— 更强的写法：整份解出来的参数直接相等。
        #expect(config.style == SubtitleDisplayStyle())
        #expect(config.style.resolved(height: 220) == SubtitleDisplayStyle().resolved(height: 220))
    }

    @Test("开关只是「画不画」：它不进显示参数")
    func visibilityDoesNotAffectStyle() {
        #expect(SubtitleDisplayConfig(isVisible: false).style == SubtitleDisplayConfig(isVisible: true).style)
    }

    @Test("持久化往返：写出去再读回来完全相同")
    func persistenceRoundTrip() {
        let config = SubtitleDisplayConfig(isVisible: false, fontScale: 1.3, position: .high, background: .solid)
        #expect(SubtitleDisplayConfig.decode(config.persistenceValue) == config)
    }

    @Test("空值 / 字段不足 / 不是数字 / 档位越界：整体回落默认")
    func decodeFallsBack() {
        #expect(SubtitleDisplayConfig.decode(nil) == SubtitleDisplayConfig())
        #expect(SubtitleDisplayConfig.decode("") == SubtitleDisplayConfig())
        #expect(SubtitleDisplayConfig.decode("1|1.0|1") == SubtitleDisplayConfig())
        #expect(SubtitleDisplayConfig.decode("1|a|1|2") == SubtitleDisplayConfig())
        #expect(SubtitleDisplayConfig.decode("1|1.0|9|2") == SubtitleDisplayConfig())
        #expect(SubtitleDisplayConfig.decode("1|1.0|1|9") == SubtitleDisplayConfig())
    }

    @Test("越界 / NaN 都夹进范围：手改 plist 不该把字号搞成 0")
    func decodeClamps() {
        #expect(SubtitleDisplayConfig(fontScale: 99).fontScale == SubtitleDisplayConfig.fontScaleRange.upperBound)
        #expect(SubtitleDisplayConfig(fontScale: 0).fontScale == SubtitleDisplayConfig.fontScaleRange.lowerBound)
        #expect(SubtitleDisplayConfig(fontScale: .nan).fontScale == SubtitleDisplayConfig.fontScaleRange.lowerBound)
        #expect(SubtitleDisplayConfig(fontScale: .infinity).fontScale == SubtitleDisplayConfig.fontScaleRange.upperBound)
        // 从存档读进来时同样夹
        #expect(SubtitleDisplayConfig.decode("1|99|1|2").fontScale == SubtitleDisplayConfig.fontScaleRange.upperBound)
    }

    @Test("位置档位 = 底边距的倍率：低那一档与原行为相等，往外逐档加大")
    func positionScalesInset() {
        let low = SubtitleDisplayConfig(position: .low).style.bottomInset
        let middle = SubtitleDisplayConfig(position: .middle).style.bottomInset
        let high = SubtitleDisplayConfig(position: .high).style.bottomInset

        #expect(low == SubtitleDisplayStyle().bottomInset) // 「低」= 原行为，默认档不能漂
        #expect(middle > low)
        #expect(high > middle)
    }

    @Test("背景档位 = 那层底的不透明度：无 = 0、半透明 = 默认、深色更实")
    func backgroundOpacity() {
        #expect(SubtitleDisplayConfig(background: .none).style.backgroundOpacity == 0)
        #expect(SubtitleDisplayConfig(background: .translucent).style.backgroundOpacity
            == SubtitleDisplayStyle().backgroundOpacity)
        #expect(SubtitleDisplayConfig(background: .solid).style.backgroundOpacity > SubtitleDisplayStyle().backgroundOpacity)
    }

    @Test("字号倍率乘在「按画面高度缩放」之后：两个默认值都不影响对方")
    func fontScaleMultiplies() {
        // 参考高度下：高度缩放 = 1，于是字号就是基准字号 × 用户倍率
        #expect(SubtitleDisplayConfig(fontScale: 1.5).style.resolved(height: 220).fontSize == 30)
        #expect(SubtitleDisplayConfig(fontScale: 1).style.resolved(height: 220).fontSize == 20)
        // 大画面上两者依然相乘（高度缩放被夹在上限 1.8）
        #expect(SubtitleDisplayConfig(fontScale: 1.5).style.resolved(height: 700).fontSize == 20 * 1.8 * 1.5)
    }

    @Test("位置与字号一起作用：改字号不该把位置档位吃掉")
    func positionAndFontScaleCombine() {
        // 用户倍率上限是 1.6（fontScaleRange），测试值必须落在范围内 —— 2 会被夹成 1.6。
        let config = SubtitleDisplayConfig(fontScale: 1.5, position: .middle)
        let style = config.style.resolved(height: 220)
        #expect(style.fontSize == 30) // 20 × 1（高度）× 1.5（用户）
        #expect(style.bottomInset == SubtitleDisplayStyle().bottomInset * SubtitlePosition.middle.insetScale * 1.5)
    }
}
