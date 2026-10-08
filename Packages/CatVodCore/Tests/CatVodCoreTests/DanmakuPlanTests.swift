@testable import CatVodCore
import Testing

/// 弹幕调度（M08d）：轨道分配、出现/退出窗口、追尾判定、挤满就丢。
///
/// 这块是弹幕里唯一「算错了肉眼也难发现」的地方 —— 叠在一起只让人觉得「有点乱」。
/// 所以测试不靠「看着对不对」，而是直接断言几何：同轨道相邻两条的间距、进出时刻的横向位置。
@Suite("弹幕调度计划")
struct DanmakuPlanTests {
    /// 一个几何很好算的版式：高 280 / 行高 28 → 10 条轨道；顶部底部各留 3 → 滚动区 4 条。
    private let layout = DanmakuPlan.Layout(
        screenWidth: 400,
        screenHeight: 280,
        laneHeight: 28,
        fixedLaneCount: 3,
        scrollDuration: 9,
        fixedDuration: 5,
        gap: 12
    )

    private func line(_ time: Double, _ type: Int = 1, text: String = "弹幕") throws -> DanmakuLine {
        try #require(DanmakuLine(params: "\(time),\(type),25,16777215", text: text))
    }

    /// 固定宽度：把断言与字体度量彻底解耦（宽度是注入的，这正是它被抽出来的原因）。
    private func plan(_ lines: [DanmakuLine], width: Double = 100) -> DanmakuPlan {
        DanmakuPlan(lines: lines, layout: layout) { _ in width }
    }

    @Test("轨道数：总轨道减掉顶部与底部各留的几条")
    func laneCount() {
        #expect(layout.scrollLaneCount == 4)

        let tight = DanmakuPlan.Layout(
            screenWidth: 400,
            screenHeight: 60,
            laneHeight: 28,
            fixedLaneCount: 3,
            scrollDuration: 9,
            fixedDuration: 5,
            gap: 12
        )
        #expect(tight.scrollLaneCount == 1) // 高度不够也只能给 1 条，不能是 0 或负数
    }

    @Test("出现与退出窗口：开始前不显示、窗口内显示、结束后不显示")
    func timeWindow() throws {
        let value = try plan([line(10)])

        #expect(value.items(at: 9.9).isEmpty)
        #expect(value.items(at: 10).count == 1)
        #expect(value.items(at: 14).count == 1)
        #expect(value.items(at: 19).isEmpty)
    }

    @Test("横向位置：出现时在右边缘，退出时整条已滑出左侧")
    func scrollGeometry() throws {
        let value = try plan([line(10)], width: 100)
        let item = try #require(value.scheduled.first)

        #expect(DanmakuPlan.scrollX(for: item, at: 10, layout: layout) == 400)
        #expect(abs(DanmakuPlan.scrollX(for: item, at: 19, layout: layout) + 100) < 0.001)
        // 速度 =（屏宽 + 文本宽）/ 时长
        #expect(abs(DanmakuPlan.speed(for: item, layout: layout) - 500.0 / 9.0) < 0.001)
    }

    @Test("同轨道相邻两条：后一条进场时，前一条的尾巴必须已经完整进场（留出间隙）")
    func noOverlapInLane() throws {
        // 同一时刻 6 条：滚动区只有 4 条轨道，多出来的会被丢
        let lines = try (0 ..< 6).map { try line(Double($0) * 0.5, text: "第\($0)条") }
        let value = plan(lines)

        var lanes: [Int: [DanmakuPlan.Item]] = [:]
        for item in value.scheduled {
            guard case let .scroll(lane) = item.placement else { continue }
            lanes[lane, default: []].append(item)
        }
        for (_, items) in lanes {
            let ordered = items.sorted { $0.start < $1.start }
            for (previous, next) in zip(ordered, ordered.dropFirst()) {
                let x = DanmakuPlan.scrollX(for: previous, at: next.start, layout: layout)
                #expect(
                    x + previous.width + layout.gap <= layout.screenWidth + 0.001,
                    "同轨道上后一条进场时，前一条还没让开"
                )
            }
        }
    }

    @Test("追尾：后一条更宽（也更快）时，时间再近也不能排进同一条轨道")
    func noRearEndCollision() throws {
        let narrow = try line(0, text: "短")
        let wide = try line(0.2, text: "很长很长很长很长很长很长很长很长")
        let value = DanmakuPlan(lines: [narrow, wide], layout: layout) { item in
            item.text.count > 4 ? 380 : 60
        }

        let placements = value.scheduled.map(\.placement)
        // 两条都被排下了，但**不在同一条轨道**（否则宽的会追上前面的窄弹幕）
        #expect(placements.count == 2)
        if case let .scroll(first) = placements[0], case let .scroll(second) = placements[1] {
            #expect(first != second)
        }
    }

    @Test("顶部 / 底部：占住轨道直到停留结束，之后可以复用")
    func fixedLanesRelease() throws {
        let first = try line(0, 5, text: "顶1")
        let tooSoon = try line(1, 5, text: "顶2")
        let after = try line(6, 5, text: "顶3")
        let value = plan([first, tooSoon, after])

        let placements = value.scheduled.compactMap { item -> Int? in
            guard case let .fixed(lane, atTop) = item.placement, atTop else { return nil }
            return lane
        }
        #expect(placements.count == 3)
        #expect(placements[0] != placements[1]) // 还在停留 → 换一条
        #expect(placements[0] == placements[2]) // 停留结束 → 第一条轨道可复用
    }

    @Test("顶部 / 底部挤满：超过保留轨道数的多出来的丢掉（宁可少显示，也不叠着）")
    func saturatedFixedLanesDrop() throws {
        let lines = try (0 ..< 8).map { try line(Double($0) * 0.1, 5, text: "顶\($0)") }
        let value = plan(lines)

        #expect(value.scheduled.count == layout.fixedLaneCount)
    }

    @Test("滚动区挤满：同一时刻超过轨道数的弹幕被丢掉")
    func saturatedScrollLanesDrop() throws {
        let lines = try (0 ..< 10).map { try line(0, 1, text: "第\($0)条") }
        let value = plan(lines)

        #expect(value.scheduled.count == layout.scrollLaneCount)
    }
}
