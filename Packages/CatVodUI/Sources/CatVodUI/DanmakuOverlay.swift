import CatVodCore
import SwiftUI

// 弹幕上屏（M08h）：把 `DanmakuPlan` 排好的计划画到视频上。
//
// 这一层只做**三件**事，每件都能单独看：
//   1. `DanmakuClock`：把引擎每秒报一次的位置外推成连续时间（纯逻辑，有单测）；
//   2. `DanmakuOverlayGeometry`：计划 + 时刻 → 要画的条目（几何，纯逻辑，有单测）；
//   3. `DanmakuOverlay`：`Canvas` 每帧把条目画出来（这一件只能靠眼睛验）。
//
// 为什么把 1、2 抽出来单测：它们错了都**不会崩、只会「感觉不太对」** ——
// 弹幕比画面慢半拍、两条挤在同一轨道、底部弹幕排到屏幕外面。这类错在真机上极难定位，
// 而它们本身是纯算术。

/// 播放时间的外推（M08h）。
///
/// 为什么需要它：系统内核的 `addPeriodicTimeObserver` 是**每秒**一次
/// （`SystemPlayerEngine+Monitoring.swift` 里 `interval = 1s`）。直接把最后一次位置喂给弹幕，
/// 弹幕会「一秒跳一格」—— 25 号字一格能跳十几个字宽。
///
/// 规则：记下「引擎报的位置」与「它是什么时候报的」，两点之间按速率线性外推。
/// 暂停 / 缓冲时速率为 0，时间就不动（弹幕自然停住），不需要额外分支。
struct DanmakuClock: Equatable {
    /// 引擎最后报的位置（秒）。
    private(set) var position: Double = 0
    /// 那个位置的采样时刻；`.distantPast` 表示还没采过样。
    private(set) var sampledAt: Date = .distantPast
    /// 每秒前进多少秒（倍速；暂停 / 缓冲 = 0）。
    private(set) var rate: Double = 0

    /// 引擎报位置时调一次。
    mutating func sample(position: Double, rate: Double, at date: Date) {
        self.position = position
        self.rate = max(0, rate)
        sampledAt = date
    }

    /// 只改速率（暂停 / 继续 / 变速）。
    ///
    /// 关键在**先外推再改**：暂停发生在两次位置上报之间，如果直接换速率，
    /// 这一段「已经走过的距离」就丢了，弹幕会往回跳一下。
    mutating func setRate(_ rate: Double, at date: Date) {
        position = time(at: date)
        self.rate = max(0, rate)
        sampledAt = date
    }

    /// 某一时刻的播放位置。
    ///
    /// 还没采过样时返回 `position`（初始 0）。外推量夹到 0 以上：系统时间被改、
    /// 或采样时刻落在未来时，宁可停在原地也不要倒退。
    func time(at date: Date) -> Double {
        guard sampledAt != .distantPast else {
            return position
        }
        let elapsed = max(0, date.timeIntervalSince(sampledAt))
        return position + elapsed * rate
    }

    /// 是否在走。暂停时让 `TimelineView` 停下来 —— 画面没变还每秒刷 60 次纯属浪费电。
    var isRunning: Bool {
        sampledAt != .distantPast && rate > 0
    }
}

/// 弹幕上屏的显示参数。
///
/// M08h 先用固定默认值；设置页那组「字号 / 透明度 / 显示区域 / 速度」是下一步（改这里就行）。
///
/// 为什么字号与行高**按画面尺寸解出来**而不是写死：同一份 25 号弹幕，在 iPhone 竖屏的
/// 16:9 视频区（高约 220pt）与 Mac 窗口（可能 700pt 高）上是同一个字号的话，
/// 小屏刚好、大屏就小得看不清。所以给一个「参考高度」，其余尺寸按比例缩放，
/// 并夹在上下限之间 —— 极端窗口下既不要把弹幕撑成一屏两行，也不要缩成一条线。
struct DanmakuDisplayStyle: Equatable {
    /// 弹幕自带 `size`（常见 25）到实际字号的**基准**比例。
    var fontScale: Double = 0.8
    /// 行高 = 字号 × 这个比例（给相邻弹幕之间留一口气）。
    var laneHeightRatio: Double = 1.4
    /// 整层不透明度。
    var opacity: Double = 1
    /// 滚动弹幕划过整屏的时长（秒）：越大越慢（设置页的「速度」对的就是它）。
    var scrollDuration: Double = 9
    /// 顶部 / 底部弹幕的停留时长（秒）。
    var fixedDuration: Double = 5
    /// 顶部 / 底部各保留几条轨道。
    var fixedLaneCount: Int = 3
    /// 字号缩放的参考画面高度（pt）。
    var referenceHeight: Double = 220
    /// 缩放后的字号比例上下限。
    var minFontScale: Double = 0.45
    var maxFontScale: Double = 1.6

    /// 排轨道时用的「典型字号」：弹幕文件里绝大多数行都是 25（也是解析器缺省值），
    /// 轨道高度按它算；个别超大字号的行会顶到相邻轨道一点 —— 比其他弹幕挤在一起轻得多。
    static let typicalFontSize: Double = 25
    /// 坏行保护：单条弹幕字号再离谱也不超出这个范围。
    static let fontSizeLimits: ClosedRange<Double> = 1 ... 60

    /// 解出某个画面尺寸下的实际参数（版面 + 不透明度 + 字号换算）。
    func resolved(width: Double, height: Double) -> DanmakuResolvedStyle {
        let scale = min(
            max(fontScale * (height / max(referenceHeight, 1)), minFontScale),
            maxFontScale
        )
        return DanmakuResolvedStyle(
            layout: DanmakuPlan.Layout(
                screenWidth: width,
                screenHeight: height,
                laneHeight: Self.typicalFontSize * scale * laneHeightRatio,
                fixedLaneCount: fixedLaneCount,
                scrollDuration: scrollDuration,
                fixedDuration: fixedDuration
            ),
            opacity: opacity,
            fontScale: scale
        )
    }
}

/// 解好尺寸之后的显示参数。宽度度量与轨道高度**必须**都从这里取，
/// 否则会出现「按 20 号字量宽度、按 28 点排轨道」这种看不出来的错位。
struct DanmakuResolvedStyle: Equatable {
    let layout: DanmakuPlan.Layout
    let opacity: Double
    let fontScale: Double

    /// 某条弹幕实际用的字号。
    func fontSize(of line: DanmakuLine) -> Double {
        let limits = DanmakuDisplayStyle.fontSizeLimits
        return min(max(line.size, limits.lowerBound), limits.upperBound) * fontScale
    }
}

/// 一条要画的弹幕（几何算完的结果，渲染层照着画）。
struct DanmakuDrawCommand: Equatable {
    let text: String
    /// 文本左边缘（点，可为负 —— 正在往左离场）。
    let x: Double
    /// 文本上边缘（已经做了轨道内的竖直居中）。
    let y: Double
    let fontSize: Double
    /// 文字色（0xAARRGGBB）。
    let color: UInt32
    /// 描边色（``DanmakuLine/shadowColor``）。
    let strokeColor: UInt32
}

/// 计划 + 时刻 → 要画什么、画在哪（纯几何）。
enum DanmakuOverlayGeometry {
    /// 轨道在屏幕上的上边缘。
    ///
    /// 三种排法的位置关系（轨道号都是该区域内从 0 起）：
    /// - 滚动区从「顶部保留区」下面开始 —— 与 ``DanmakuPlan/Layout/scrollLaneCount``
    ///   把滚动区算成「总轨道数 − 2 × 保留数」一致；
    /// - 顶部弹幕从第 0 条往下排；
    /// - 底部弹幕从屏幕底**往上**排（第 0 条在最下面）—— 与「后来的往上顶」的观感一致。
    static func top(of placement: DanmakuPlan.Item.Placement, layout: DanmakuPlan.Layout) -> Double {
        switch placement {
        case let .scroll(lane):
            return Double(max(layout.fixedLaneCount, 0) + max(lane, 0)) * layout.laneHeight
        case let .fixed(lane, atTop):
            let index = max(lane, 0)
            if atTop {
                return Double(index) * layout.laneHeight
            }
            return layout.screenHeight - Double(index + 1) * layout.laneHeight
        }
    }

    /// 某一时刻要画的条目。
    ///
    /// 两处过滤，都是「计划里有、但此刻不该画」：
    /// 1. `plan.items(at:)` 已经按出现 / 退出时刻筛过一遍；
    /// 2. 这里再丢掉**整条已经滑出左侧**的 —— 计划窗口是按退出时刻算的，
    ///    而几何上它可能已经走完了（宽弹幕尤其明显）。
    static func commands(
        plan: DanmakuPlan,
        at time: Double,
        style: DanmakuResolvedStyle
    ) -> [DanmakuDrawCommand] {
        let layout = style.layout
        return plan.items(at: time).compactMap { item in
            let fontSize = style.fontSize(of: item.line)
            let x: Double
            switch item.placement {
            case .scroll:
                x = DanmakuPlan.scrollX(for: item, at: time, layout: layout)
            case .fixed:
                // 顶部 / 底部水平居中（用计划里量好的宽度，不再量一次）。
                x = (layout.screenWidth - item.width) / 2
            }
            guard x + item.width > 0 else {
                return nil
            }
            return DanmakuDrawCommand(
                text: item.line.text,
                x: x,
                y: top(of: item.placement, layout: layout) + max(0, (layout.laneHeight - fontSize) / 2),
                fontSize: fontSize,
                color: item.line.color,
                strokeColor: item.line.shadowColor
            )
        }
    }
}

/// 一次排好的弹幕上屏数据。
///
/// 计划与版面**绑在一起**存：两者必须同源（同一个画面尺寸、同一份字号参数），
/// 否则会出现「计划按 390×219 排的、画的时候按 400×225 算」这种错位 —— 轨道会错开半条。
struct DanmakuRenderPlan {
    let plan: DanmakuPlan
    let style: DanmakuResolvedStyle
}

/// 弹幕覆盖层：每帧按播放时间取条目并画出来。
///
/// 三点刻意的做法：
/// - `TimelineView(.animation(minimumInterval:paused:))`：**逐帧**取时间（不是每秒），
///   暂停 / 缓冲时直接停表；上限 60fps —— ProMotion 上的 120fps 对弹幕没有意义，只是双倍开销。
/// - 画在 `Canvas` 里而不是堆 `Text` 视图：几十条同时在场，视图树会先崩在布局上。
/// - `.allowsHitTesting(false)`：这一层只负责看，触摸留给系统与下层的播放控件。
///
/// 描边用 0.8 半径的阴影近似：`GraphicsContext` 没有描边文字，而上游的 `shadow` 本来就是
/// 「文字周围一圈」（``DanmakuLine/shadowColor``）。
///
/// 已知粗糙处：系统内核的控制条由 `VideoPlayer` 自己画，它在**这一层下面** ——
/// 点开控制条时弹幕会从控件上划过去。换成自绘控制层（M3/M4 的 MPV / FFmpeg 内核）后
/// 这个问题自然消失，先不为它绕路。
struct DanmakuOverlay: View {
    let plan: DanmakuPlan
    let style: DanmakuResolvedStyle
    let clock: DanmakuClock

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !clock.isRunning)) { context in
            Canvas { graphics, _ in
                let commands = DanmakuOverlayGeometry.commands(
                    plan: plan,
                    at: clock.time(at: context.date),
                    style: style
                )
                for command in commands {
                    var layer = graphics
                    layer.opacity = style.opacity
                    layer.addFilter(.shadow(color: Color(argb: command.strokeColor), radius: 0.8))
                    layer.draw(
                        Text(command.text)
                            .font(.system(size: CGFloat(command.fontSize)))
                            .foregroundColor(Color(argb: command.color)),
                        at: CGPoint(x: CGFloat(command.x), y: CGFloat(command.y)),
                        anchor: .topLeading
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension Color {
    /// 0xAARRGGBB（上游给的颜色就是这个形态）→ `Color`。
    init(argb: UInt32) {
        let parts = Self.components(ofARGB: argb)
        self.init(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: parts.alpha)
    }

    /// 拆出四个 0…1 分量。
    ///
    /// 单独成函数是为了能测：`Color` 拿不回分量，比不了大小，而拆错一位就是「红色变蓝色」
    /// 这种一眼看不出对错的错。
    static func components(ofARGB value: UInt32) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: Double((value >> 24) & 0xFF) / 255
        )
    }
}
