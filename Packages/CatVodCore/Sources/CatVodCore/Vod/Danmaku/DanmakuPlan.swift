import Foundation

/// 弹幕上屏的**调度计划**（M08d）：每条弹幕进哪条轨道、什么时刻出现、划过时的横向位置。
///
/// 为什么把调度单独拿出来、还不碰任何 UI 类型：弹幕里唯一「会算错、而且很难肉眼发现」的就是它 ——
/// 两条弹幕叠在一起、或者一条还没划完就被下一条追尾，肉眼只看到「有点乱」，说不上哪里错。
/// 而规则本身是纯几何：给定屏幕宽高与字号，位置就该算得出来，所以它完全可测。
///
/// 用法：``DanmakuLine`` 载入后构造一次计划（O(行数 × 轨道数)），之后每帧只做一次二分 + 几何计算。
public struct DanmakuPlan: Sendable {
    /// 上屏参数（渲染层给；真实文本宽度由 ``WidthProvider`` 提供）。
    public struct Layout: Sendable, Equatable {
        public var screenWidth: Double
        public var screenHeight: Double
        /// 单条弹幕的行高。
        public var laneHeight: Double
        /// 顶部 / 底部区域各保留几条轨道（滚动区 = 总轨道数 − 2 × 这个值）。
        public var fixedLaneCount: Int
        /// 一条滚动弹幕划过整屏的时长（秒）。
        public var scrollDuration: Double
        /// 顶部 / 底部弹幕的停留时长（秒）。
        public var fixedDuration: Double
        /// 弹幕之间的最小横向间隙。
        public var gap: Double

        public init(
            screenWidth: Double,
            screenHeight: Double,
            laneHeight: Double = 28,
            fixedLaneCount: Int = 3,
            scrollDuration: Double = 9,
            fixedDuration: Double = 5,
            gap: Double = 12
        ) {
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.laneHeight = laneHeight
            self.fixedLaneCount = fixedLaneCount
            self.scrollDuration = scrollDuration
            self.fixedDuration = fixedDuration
            self.gap = gap
        }

        /// 滚动区的轨道数：总轨道数减掉顶部 / 底部各留的那几条，至少 1 条。
        public var scrollLaneCount: Int {
            let total = max(1, Int(screenHeight / max(laneHeight, 1)))
            return max(1, total - 2 * max(fixedLaneCount, 0))
        }
    }

    /// 文本宽度提供者：调度只做几何，量字宽是渲染层的事（Core 里没有字体度量）。
    /// 注入它还有个好处：单测给「固定宽度」就能断言，结果与字体无关。
    public typealias WidthProvider = @Sendable (DanmakuLine) -> Double

    /// 一条已排好位置的弹幕。
    public struct Item: Sendable, Equatable {
        public enum Placement: Sendable, Equatable {
            /// 滚动（`lane` 是滚动区的轨道号）。**横向位置按时间算**，见 ``scrollX(for:at:layout:)`` ——
            /// 位置是时间的函数，不该被冻在条目里。
            case scroll(lane: Int)
            /// 顶部 / 底部：水平居中，`lane` 从对应区域数。
            case fixed(lane: Int, atTop: Bool)
        }

        public let line: DanmakuLine
        public let placement: Placement
        public let width: Double
        /// 出现时刻与退出时刻（秒）。
        public let start: Double
        public let end: Double
    }

    /// 滚动弹幕的速度（点/秒）：时长固定 ⇒ **越宽的弹幕划得越快**（这正是「追尾」会发生的原因）。
    public static func speed(for item: Item, layout: Layout) -> Double {
        (layout.screenWidth + item.width) / max(layout.scrollDuration, 0.1)
    }

    /// 滚动弹幕在某一时刻的文本左边缘（可为负 —— 表示正在往左离开屏幕）。
    public static func scrollX(for item: Item, at time: Double, layout: Layout) -> Double {
        layout.screenWidth - (time - item.start) * speed(for: item, layout: layout)
    }

    private let items: [Item]
    /// 单条最长时长（滚动与停留取大者）：找「这一刻该显示谁」时用它收窄扫描范围。
    private let maxDuration: Double

    /// 排一次计划。`lines` 不必有序（内部按时间排）；放不下的弹幕**直接丢掉**（宁可少显示，也不叠着）。
    public init(lines: [DanmakuLine], layout: Layout, width: @escaping WidthProvider) {
        items = DanmakuPlan.plan(lines: lines, layout: layout, width: width)
        maxDuration = max(layout.scrollDuration, layout.fixedDuration)
    }

    /// 计划里的全部条目（按出现时间排好；单测与调试用）。
    public var scheduled: [Item] {
        items
    }

    /// 某一时刻该显示的弹幕。
    ///
    /// 计划按 `start` 有序，每条时长不超过 ``maxDuration`` ⇒ 能覆盖 `time` 的必然落在
    /// `[time - maxDuration, time]` 里：先二分定位「最后一条已开始」的条目，再往回扫到窗口外。
    /// 这样每帧是 O(log n + 窗口内条数)，几万条弹幕也不会因为每帧全扫而掉帧。
    public func items(at time: Double) -> [Item] {
        guard !items.isEmpty else {
            return []
        }
        var result: [Item] = []
        var index = upperBound(of: time)
        while index >= 0 {
            let item = items[index]
            if item.start < time - maxDuration {
                break
            }
            if item.end >= time {
                result.append(item)
            }
            index -= 1
        }
        return result.reversed()
    }

    /// 最后一个 `start <= time` 的下标（没有则 -1）。
    private func upperBound(of time: Double) -> Int {
        var low = 0
        var high = items.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if items[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    // MARK: - 排布

    private static func plan(lines: [DanmakuLine], layout: Layout, width: WidthProvider) -> [Item] {
        let sorted = lines.sorted { $0.time < $1.time }
        var planned: [Item] = []
        // 每条轨道上最后一条（用来判断能不能再排一条进同一条轨道）
        var scrollLanes = [Item?](repeating: nil, count: layout.scrollLaneCount)
        var topLanes = [Item?](repeating: nil, count: max(layout.fixedLaneCount, 0))
        var bottomLanes = [Item?](repeating: nil, count: max(layout.fixedLaneCount, 0))

        for line in sorted {
            let textWidth = max(width(line), 1)
            if line.isScroll {
                guard let lane = scrollLane(scrollLanes, line: line, width: textWidth, layout: layout) else {
                    continue // 滚动区挤满 → 丢掉这一条
                }
                let item = Item(
                    line: line,
                    placement: .scroll(lane: lane),
                    width: textWidth,
                    start: line.time,
                    end: line.time + max(layout.scrollDuration, 0.1)
                )
                planned.append(item)
                scrollLanes[lane] = item
            } else {
                let isTop = line.isTop
                var lanes = isTop ? topLanes : bottomLanes
                guard let lane = fixedLane(lanes, line: line) else {
                    continue // 顶部 / 底部挤满 → 丢掉
                }
                let item = Item(
                    line: line,
                    placement: .fixed(lane: lane, atTop: isTop),
                    width: textWidth,
                    start: line.time,
                    end: line.time + max(layout.fixedDuration, 0.1)
                )
                planned.append(item)
                lanes[lane] = item
                if isTop {
                    topLanes = lanes
                } else {
                    bottomLanes = lanes
                }
            }
        }
        return planned.sorted { $0.start < $1.start }
    }

    /// 找一条能进滚动弹幕的轨道；找不到返回 nil（这条丢掉）。
    private static func scrollLane(
        _ lanes: [Item?],
        line: DanmakuLine,
        width: Double,
        layout: Layout
    ) -> Int? {
        for (index, previous) in lanes.enumerated() {
            guard let previous else {
                return index
            }
            if canFollow(previous, line: line, width: width, layout: layout) {
                return index
            }
        }
        return nil
    }

    /// 新弹幕能不能跟在前一条后面进同一条轨道。两个条件都要满足：
    ///
    /// 1. 前一条的**尾巴已经完整进场**（留出 `gap`）—— 否则一进场两条就叠着；
    /// 2. 新的那条**追不上**前一条 —— 时长固定 ⇒ 宽弹幕更快，窄的追宽的是真会发生的事。
    ///    两条的横向间隔只会在「前一条离场」那一刻最小（速度恒定、间隔单调），所以只查那一瞬间。
    private static func canFollow(_ previous: Item, line: DanmakuLine, width: Double, layout: Layout) -> Bool {
        let previousSpeed = speed(for: previous, layout: layout)
        let elapsed = line.time - previous.start
        guard elapsed * previousSpeed >= previous.width + layout.gap else {
            return false
        }
        let overlapEnd = min(line.time + max(layout.scrollDuration, 0.1), previous.end)
        let newLeft = layout.screenWidth - (overlapEnd - line.time) * speed(forLineWidth: width, layout: layout)
        let previousRight = layout.screenWidth - (overlapEnd - previous.start) * previousSpeed + previous.width
        return newLeft >= previousRight + layout.gap
    }

    /// 只按宽度算速度（排布阶段还没有 `Item`）。
    private static func speed(forLineWidth width: Double, layout: Layout) -> Double {
        (layout.screenWidth + width) / max(layout.scrollDuration, 0.1)
    }

    /// 顶部 / 底部：轨道空着就行（停留时长的语义是「占住这条轨道」，不做横向碰撞）。
    private static func fixedLane(_ lanes: [Item?], line: DanmakuLine) -> Int? {
        for (index, previous) in lanes.enumerated() {
            guard let previous else {
                return index
            }
            if previous.end + 0.01 <= line.time {
                return index
            }
        }
        return nil
    }
}
