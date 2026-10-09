import CatVodCore
@testable import CatVodUI
import SwiftUI
import Testing

@Suite("弹幕上屏：几何与显示参数")
struct DanmakuOverlayTests {
    // MARK: - 造数据

    private func makeLayout(
        width: Double = 400,
        height: Double = 300,
        laneHeight: Double = 30,
        fixedLaneCount: Int = 2,
        scrollDuration: Double = 8,
        fixedDuration: Double = 4
    ) -> DanmakuPlan.Layout {
        DanmakuPlan.Layout(
            screenWidth: width,
            screenHeight: height,
            laneHeight: laneHeight,
            fixedLaneCount: fixedLaneCount,
            scrollDuration: scrollDuration,
            fixedDuration: fixedDuration
        )
    }

    private func makeLine(_ params: String, _ text: String = "弹幕") throws -> DanmakuLine {
        try #require(DanmakuLine(params: params, text: text))
    }

    /// 固定宽度 100：几何完全可断言（与字体解耦正是 `DanmakuPlan` 注入宽度提供者的用意）。
    private func makePlan(_ lines: [DanmakuLine], layout: DanmakuPlan.Layout, width: Double = 100) -> DanmakuPlan {
        DanmakuPlan(lines: lines, layout: layout, width: { _ in width })
    }

    private func makeStyle(_ layout: DanmakuPlan.Layout, fontScale: Double = 1) -> DanmakuResolvedStyle {
        DanmakuResolvedStyle(layout: layout, opacity: 1, fontScale: fontScale)
    }

    // MARK: - 几何

    @Test("滚动轨道从顶部保留区之下开始（与计划把滚动区算成「总数 − 2 × 保留数」一致）")
    func scrollLaneTops() {
        let layout = makeLayout()
        #expect(DanmakuOverlayGeometry.top(of: .scroll(lane: 0), layout: layout) == 60)
        #expect(DanmakuOverlayGeometry.top(of: .scroll(lane: 3), layout: layout) == 150)
    }

    @Test("顶部从上往下排；底部从屏幕底往上排")
    func fixedLaneTops() {
        let layout = makeLayout()
        #expect(DanmakuOverlayGeometry.top(of: .fixed(lane: 0, atTop: true), layout: layout) == 0)
        #expect(DanmakuOverlayGeometry.top(of: .fixed(lane: 1, atTop: true), layout: layout) == 30)
        // 300 高、行高 30：底部第 0 条占 270…300，第 2 条占 210…240
        #expect(DanmakuOverlayGeometry.top(of: .fixed(lane: 0, atTop: false), layout: layout) == 270)
        #expect(DanmakuOverlayGeometry.top(of: .fixed(lane: 2, atTop: false), layout: layout) == 210)
    }

    @Test("保留轨道数为 0 时也不出负位置")
    func zeroFixedLanes() {
        let layout = makeLayout(fixedLaneCount: 0)
        #expect(DanmakuOverlayGeometry.top(of: .scroll(lane: 0), layout: layout) == 0)
        #expect(DanmakuOverlayGeometry.top(of: .scroll(lane: 2), layout: layout) == 60)
    }

    @Test("滚动弹幕：位置用计划那条公式，且在轨道内竖直居中")
    func scrollCommandPlacement() throws {
        let layout = makeLayout()
        let plan = try makePlan([makeLine("1.0,1,20,16777215", "滚动")], layout: layout)
        let style = makeStyle(layout)

        let atStart = try #require(DanmakuOverlayGeometry.commands(plan: plan, at: 1.0, style: style).first)
        #expect(abs(atStart.x - 400) < 0.0001) // 进场：左边缘正好在屏宽处
        #expect(abs(atStart.y - 65) < 0.0001) // 60 + (30 − 20) / 2
        #expect(atStart.fontSize == 20)

        // 速度 = (400 + 100) / 8 = 62.5/s ⇒ 2 秒后左边缘在 400 − 125
        let later = try #require(DanmakuOverlayGeometry.commands(plan: plan, at: 3.0, style: style).first)
        #expect(abs(later.x - (400 - 62.5 * 2)) < 0.0001)
        #expect(abs(later.y - 65) < 0.0001)
    }

    @Test("顶部 / 底部弹幕水平居中（用计划量好的宽度，不再量第二次）")
    func fixedCommandIsCentered() throws {
        let layout = makeLayout()
        let plan = try makePlan([makeLine("1.0,5,20,16777215", "顶部")], layout: layout)
        let style = makeStyle(layout)
        let commands = DanmakuOverlayGeometry.commands(plan: plan, at: 1.0, style: style)
        let command = try #require(commands.first)
        #expect(abs(command.x - 150) < 0.0001) // (400 − 100) / 2
        #expect(command.y == 5) // 顶部第 0 条：(30 − 20) / 2
    }

    @Test("时间窗口外不画：还没出现、以及早就过期的都不在")
    func commandsRespectWindow() throws {
        let layout = makeLayout()
        let plan = try makePlan([makeLine("10.0,1,20,16777215", "十秒")], layout: layout)
        let style = makeStyle(layout)
        #expect(DanmakuOverlayGeometry.commands(plan: plan, at: 5.0, style: style).isEmpty)
        #expect(DanmakuOverlayGeometry.commands(plan: plan, at: 9.0, style: style).isEmpty)
        #expect(DanmakuOverlayGeometry.commands(plan: plan, at: 10.0, style: style).count == 1)
    }

    @Test("整条已经滑出左侧的丢掉：计划窗口还在，几何上已经走完")
    func commandsDropOffscreenLeft() throws {
        let layout = makeLayout()
        let plan = try makePlan([makeLine("1.0,1,20,16777215", "宽弹幕")], layout: layout, width: 200)
        // 速度 = (400 + 200) / 8 = 75/s ⇒ t = 9 时左边缘 −200、右边缘正好 0
        #expect(abs(DanmakuPlan.scrollX(for: plan.scheduled[0], at: 9.0, layout: layout) + 200) < 0.0001)
        #expect(DanmakuOverlayGeometry.commands(plan: plan, at: 9.0, style: makeStyle(layout)).isEmpty)
    }

    // MARK: - 显示参数

    @Test("字号随画面高度缩放，并夹在上下限内")
    func styleResolvesFontScale() {
        let style = DanmakuDisplayStyle()

        let phone = style.resolved(width: 390, height: 220)
        #expect(abs(phone.fontScale - 0.8) < 0.0001) // 参考高度 ⇒ 基准比例
        #expect(abs(phone.layout.laneHeight - 25 * 0.8 * 1.4) < 0.0001)

        // 大窗口不把弹幕放大到离谱，小窗口也不缩成一条线
        #expect(style.resolved(width: 900, height: 700).fontScale == style.maxFontScale)
        #expect(style.resolved(width: 200, height: 60).fontScale == style.minFontScale)
    }

    @Test("坏行保护：字号离谱的弹幕不会把轨道撑爆")
    func styleClampsFontSize() throws {
        let style = DanmakuDisplayStyle().resolved(width: 390, height: 220)
        let huge = try makeLine("1.0,1,999,16777215")
        #expect(abs(style.fontSize(of: huge) - 60 * style.fontScale) < 0.0001)
        let zero = try makeLine("1.0,1,0,16777215")
        #expect(abs(style.fontSize(of: zero) - 1 * style.fontScale) < 0.0001)
    }

    @Test("颜色拆分：0xAARRGGBB 各分量到位")
    func argbComponents() {
        let parts = Color.components(ofARGB: 0xFF33_66CC)
        #expect(abs(parts.red - 0x33 / 255.0) < 0.0001)
        #expect(abs(parts.green - 0x66 / 255.0) < 0.0001)
        #expect(abs(parts.blue - 0xCC / 255.0) < 0.0001)
        #expect(parts.alpha == 1)
    }

    @Test("覆盖层与上屏数据能构造（不渲染，只钉住接口）")
    @MainActor
    func viewsConstruct() throws {
        let layout = makeLayout()
        let plan = try makePlan([makeLine("1.0,1,20,16777215")], layout: layout)
        let style = makeStyle(layout)
        _ = DanmakuOverlay(plan: plan, style: style, clock: PlaybackClock())
        _ = DanmakuRenderPlan(plan: plan, style: style)
    }
}
