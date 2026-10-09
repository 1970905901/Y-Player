import CatVodCore
import SwiftUI

// 字幕上屏（M09f）：把 `SubtitleTimeline` 查到的 cue 画到视频底部。
//
// 与弹幕上屏（M08h）是同一套骨架：**内容查询**在 Core（`DanmakuPlan` / `SubtitleTimeline`），
// **几何/取哪条**是纯函数（有单测），**画**只有一层。两者共用同一个 ``PlaybackClock`` ——
// 引擎每秒才报一次位置，两个覆盖层都得外推，而且必须按**同一刻**的时间取内容。
//
// 没有合并成一个「通用覆盖层」：两者的取舍差得远 ——
// 弹幕要排轨道、算速度、几十条同屏、坐标得自己算；字幕只有一条、居中贴底、
// 交给 SwiftUI 的 `Text` 排版（换行、多行行距都是它的事）。

/// 字幕的显示参数。
///
/// M09f 先用默认值；设置页（字号 / 位置 / 背景）是下一步，改这里就行。
///
/// 与 `DanmakuDisplayStyle` 同一套「按画面高度缩放」的理由：iPhone 竖屏的视频区（高约 220pt）
/// 与 Mac 窗口用同一个字号的话，小屏刚好、大屏就小得看不清。
struct SubtitleDisplayStyle: Equatable {
    /// 基准字号（pt，参考高度下）。
    var baseFontSize: Double = 20
    /// 多行字幕的行距（pt，参考高度下）。
    var lineSpacing: Double = 5
    /// 距画面底边的距离（pt，参考高度下）：贴太紧会被画面下缘切读起来费劲。
    var bottomInset: Double = 16
    /// 整条不透明度。
    var opacity: Double = 1
    /// 字号倍率（设置页给的用户偏好，默认 1 = 不额外缩放）。
    ///
    /// 与「按画面高度缩放」分开：那一个是**为了不同设备上观感一致**的必要修正，
    /// 这一个是用户自己的偏好 —— 两者相乘，各自的默认值都不影响对方。
    var fontScale: Double = 1
    /// 文字背后那层深色底的不透明度。0 = 不要底（只靠白字加深色阴影）。
    ///
    /// 为什么默认给一层底而不是纯描边：字幕常常压在人脸或亮色画面上，
    /// 只描边的白字在亮底上照样糊；一层半透明黑底最稳。
    var backgroundOpacity: Double = 0.55
    /// 缩放后的上下限。
    var minFontScale: Double = 0.6
    var maxFontScale: Double = 1.8
    /// 字号缩放的参考画面高度（pt）。
    var referenceHeight: Double = 220

    /// 解出某个画面尺寸下的实际参数。
    ///
    /// 只按**高度**缩放：宽度不参与字号计算 —— 换行与左右留白是 `Text` 与 `.padding` 的事，
    /// 硬把宽度塞进字号换算反而会在窄窗口上把字压小。
    func resolved(height: Double) -> SubtitleResolvedStyle {
        let heightScale = min(max(height / max(referenceHeight, 1), minFontScale), maxFontScale)
        let scale = heightScale * fontScale
        return SubtitleResolvedStyle(
            fontSize: baseFontSize * scale,
            lineSpacing: lineSpacing * scale,
            bottomInset: bottomInset * scale,
            opacity: opacity,
            backgroundOpacity: backgroundOpacity
        )
    }
}

/// 解好尺寸之后的字幕参数。
struct SubtitleResolvedStyle: Equatable {
    let fontSize: Double
    let lineSpacing: Double
    let bottomInset: Double
    let opacity: Double
    let backgroundOpacity: Double
}

/// 某一时刻该画什么（纯逻辑，可测）。
enum SubtitleOverlayGeometry {
    /// 该时刻要画的字幕文本；没有、或整条都是空白，就返回 `nil`。
    ///
    /// 重叠时**拼成多行**，而不是叠着画同一行：真实字幕文件里的「重叠」几乎都是刻意的一对
    /// （原文 + 译文），叠在同一行上会互相盖住，拼成多行才是它们本来的样子。
    ///
    /// 空白 cue 当没有处理：SRT 里空行就是「这条没内容」，画一个空背景框没有意义。
    static func text(timeline: SubtitleTimeline, at time: Double) -> String? {
        let cues = timeline.cues(at: time)
        guard !cues.isEmpty else {
            return nil
        }
        let lines = cues
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// 字幕覆盖层。
///
/// 三点与弹幕层一致的做法：`TimelineView` 逐帧取时间（上限 60fps、暂停停表）、
/// `.allowsHitTesting(false)`（触摸留给系统控件）、只在不透明时占位（交给父视图判断）。
///
/// 排版交给 SwiftUI：字幕是一条文本，`Text` 自己会换行、自己会按 `lineSpacing` 排行距 ——
/// 用 `Canvas` 反而要把换行与测量都自己写一遍，而这里每帧只有一条文本，没有性能理由。
struct SubtitleOverlay: View {
    let timeline: SubtitleTimeline
    let style: SubtitleResolvedStyle
    let clock: PlaybackClock

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !clock.isRunning)) { context in
            content(at: clock.time(at: context.date))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(at time: Double) -> some View {
        if let text = SubtitleOverlayGeometry.text(timeline: timeline, at: time) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(text)
                    .font(.system(size: CGFloat(style.fontSize)))
                    .lineSpacing(CGFloat(style.lineSpacing))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Color.black.opacity(style.backgroundOpacity),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .opacity(style.opacity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, CGFloat(style.bottomInset))
            }
            .frame(maxWidth: .infinity)
        }
    }
}
