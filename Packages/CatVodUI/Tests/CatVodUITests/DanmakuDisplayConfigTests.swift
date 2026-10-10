@testable import CatVodUI
import Testing

@Suite("弹幕显示设置：默认值 / 持久化 / 上屏换算")
struct DanmakuDisplayConfigTests {
    @Test("默认值就是 M08h 的行为：不碰设置 = 什么都不变")
    func defaultsMatchBaseline() {
        let config = DanmakuDisplayConfig()
        #expect(config.isVisible)
        #expect(config.fontScale == 0.8)
        #expect(config.opacity == 1)
        #expect(config.speed == .normal)
        #expect(config.area == .full)

        // 与「渲染层自己的默认值」逐项相等：默认值不是随手定的，是回归基线 ——
        // 哪天要改它，必须是有意的（改这里就得同时说明为什么屏上观感变了）。
        let style = DanmakuDisplayStyle()
        #expect(config.style.fontScale == style.fontScale)
        #expect(config.style.opacity == style.opacity)
        #expect(config.style.scrollDuration == style.scrollDuration)
        #expect(config.style.areaFraction == style.areaFraction)
    }

    @Test("持久化往返：写出去再读回来完全相同（含总开关）")
    func persistenceRoundTrip() {
        let config = DanmakuDisplayConfig(fontScale: 1.3, opacity: 0.55, speed: .fast, area: .half)
        #expect(DanmakuDisplayConfig.decode(config.persistenceValue) == config)

        let hidden = DanmakuDisplayConfig(isVisible: false)
        #expect(DanmakuDisplayConfig.decode(hidden.persistenceValue) == hidden)
        #expect(DanmakuDisplayConfig.decode(hidden.persistenceValue).isVisible == false)
    }

    @Test("旧值兼容：M08i 那版的 4 段值没有总开关，读回来按「显示」算（M03P18）")
    func decodeAcceptsLegacyValue() {
        let legacy = DanmakuDisplayConfig.decode("1.3|0.55|3|2")
        #expect(legacy.fontScale == 1.3)
        #expect(legacy.opacity == 0.55)
        #expect(legacy.speed == .fast)
        #expect(legacy.area == .half)
        #expect(legacy.isVisible)

        // 第 5 段脏了也整体回落默认（与别的字段同一个口径）
        #expect(DanmakuDisplayConfig.decode("1.0|1.0|2|4|x") == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("1.0|1.0|2|4|") == DanmakuDisplayConfig())
    }

    @Test("空值 / 字段不足 / 不是数字 / 档位越界：整体回落默认")
    func decodeFallsBack() {
        #expect(DanmakuDisplayConfig.decode(nil) == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("") == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("1.0|1.0|2") == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("a|b|c|d") == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("1.0|1.0|9|4") == DanmakuDisplayConfig())
        #expect(DanmakuDisplayConfig.decode("1.0|1.0|2|9") == DanmakuDisplayConfig())
    }

    @Test("越界数值夹进范围：手改 plist 也不该把界面搞成「字号 0」")
    func decodeClamps() {
        let tooBig = DanmakuDisplayConfig(fontScale: 99, opacity: 5)
        #expect(tooBig.fontScale == DanmakuDisplayConfig.fontScaleRange.upperBound)
        #expect(tooBig.opacity == DanmakuDisplayConfig.opacityRange.upperBound)

        let tooSmall = DanmakuDisplayConfig(fontScale: -3, opacity: 0)
        #expect(tooSmall.fontScale == DanmakuDisplayConfig.fontScaleRange.lowerBound)
        #expect(tooSmall.opacity == DanmakuDisplayConfig.opacityRange.lowerBound)

        let decoded = DanmakuDisplayConfig.decode("99|5|2|4")
        #expect(decoded.fontScale == DanmakuDisplayConfig.fontScaleRange.upperBound)
        #expect(decoded.opacity == DanmakuDisplayConfig.opacityRange.upperBound)
    }

    @Test("NaN 落下限、±∞ 按大小夹：坏值不会传播进渲染")
    func clampHandlesNonFinite() {
        #expect(DanmakuDisplayConfig(fontScale: .nan).fontScale == DanmakuDisplayConfig.fontScaleRange.lowerBound)
        #expect(DanmakuDisplayConfig(fontScale: .infinity).fontScale == DanmakuDisplayConfig.fontScaleRange.upperBound)
        #expect(DanmakuDisplayConfig(opacity: -.infinity).opacity == DanmakuDisplayConfig.opacityRange.lowerBound)
    }

    @Test("速度档位换算成「划过整屏的秒数」：慢 > 中 > 快，且直接交给版面")
    func speedDurations() {
        #expect(DanmakuSpeed.slow.scrollDuration > DanmakuSpeed.normal.scrollDuration)
        #expect(DanmakuSpeed.normal.scrollDuration > DanmakuSpeed.fast.scrollDuration)
        #expect(DanmakuDisplayConfig(speed: .fast).style.scrollDuration == DanmakuSpeed.fast.scrollDuration)
    }

    @Test("显示区域按高度裁：区域减半，底部弹幕跟着区域的底边走，字号不变")
    func areaShrinksRegion() {
        let full = DanmakuDisplayConfig(area: .full).style.resolved(width: 400, height: 300)
        let half = DanmakuDisplayConfig(area: .half).style.resolved(width: 400, height: 300)

        #expect(full.layout.screenHeight == 300)
        #expect(half.layout.screenHeight == 150)
        // 字号不该跟着区域缩小：区域是「裁出多少地方放弹幕」，不是「把画面缩小」。
        #expect(full.fontScale == half.fontScale)
        // 底部弹幕锚在区域的底边（半屏 = 屏幕中线）。
        #expect(DanmakuOverlayGeometry.top(of: .fixed(lane: 0, atTop: false), layout: half.layout)
            == 150 - half.layout.laneHeight)
    }

    @Test("区域真的减少了轨道数：800 高时全屏 8 条滚动轨道 → 半屏 1 条")
    func areaReducesLanes() {
        let full = DanmakuDisplayConfig(area: .full).style.resolved(width: 900, height: 800)
        let half = DanmakuDisplayConfig(area: .half).style.resolved(width: 900, height: 800)
        #expect(full.layout.scrollLaneCount == 8)
        #expect(half.layout.scrollLaneCount == 1)
    }

    @Test("区域比例有下限：再小也不会算出 0 条轨道")
    func areaHasFloor() {
        var style = DanmakuDisplayStyle()
        style.areaFraction = 0
        let resolved = style.resolved(width: 400, height: 300)
        #expect(resolved.layout.screenHeight == 300 * DanmakuDisplayStyle.minAreaFraction)
        #expect(resolved.layout.scrollLaneCount >= 1)
    }
}
