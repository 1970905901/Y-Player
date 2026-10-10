import CatVodCore
import CatVodPlayer
import Foundation
import SwiftUI

/// 播放页的**覆盖层**（弹幕 M08h / 字幕 M09f）：时间轴 / 计划的构建与它们的重排键。
///
/// 只做「把数据排成能按时间取的东西」，画归 `DanmakuOverlay` / `SubtitleOverlay`，时钟归 `PlaybackClock`。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数顶到了 SwiftLint 的 `file_length` error（800）——
/// 拆文件不如拆职责：主文件留播放本体，这块独立成文件（与 `VodDetailView+Emby` 同一套做法）。
/// 跨文件的成员不能带 `private`：主文件里被这里用到的 `@State` 因此改成了默认（internal）。
extension PlaybackView {
    // MARK: - 覆盖层（弹幕 M08h / 字幕 M09f）

    /// 字幕时间轴的重排键：**只看 cue 本身**（不像弹幕还要带尺寸与显示设置 —— 字幕没有几何
    /// 烘进时间轴，字号与位置只在画的时候用）。
    ///
    /// 与 `danmakuPlanKey` 同一套理由：用「条数 + 首末开始时间」代表整份数组，
    /// 每帧都要算的键不该是 O(n)。
    var subtitleTimelineKey: String {
        let cues = subtitleCues
        return [
            String(cues.count),
            String(cues.first?.start ?? -1),
            String(cues.last?.start ?? -1),
        ].joined(separator: "|")
    }

    /// 建一次字幕时间轴。
    ///
    /// 比弹幕的计划便宜得多（排序 + 算最长时长），但仍是 O(n log n)：放进 `.task(id:)` 而不是
    /// 每次 body 都算 —— 播放中 body 会因时钟、状态、进度反复重建。
    func makeSubtitleTimeline() -> SubtitleTimeline? {
        let cues = subtitleCues
        guard !cues.isEmpty else {
            return nil
        }
        return SubtitleTimeline(cues: cues)
    }

    /// 计划重排的触发键：**行内容 / 画面尺寸 / 显示设置**任一变化都要重排。
    ///
    /// 行内容用「条数 + 首末时间」代表，而不是整份数组：比较几万条是 O(n)，而这个键每帧都要算；
    /// 换集时三者几乎必然一起变，够用（同一集重复加载同一份弹幕时结果也一样，不必重排）。
    func danmakuPlanKey(size: CGSize) -> String {
        let lines = danmakuLines
        return [
            String(lines.count),
            String(lines.first?.time ?? -1),
            String(lines.last?.time ?? -1),
            String(Int(size.width.rounded())),
            String(Int(size.height.rounded())),
            // 显示设置也要进键：字号影响宽度度量、区域影响轨道数，两者都已经烘进计划本身了。
            danmakuDisplay.persistenceValue,
        ].joined(separator: "|")
    }

    /// 排一次计划。
    ///
    /// **只在键变化时跑**：它是 O(行数 × 轨道数) 外加一次全量文本度量（几万条弹幕在设备上
    /// 是几十毫秒量级）；每帧重排会把播放拖垮。
    ///
    /// 宽度度量走 ``AdaptiveFontMetrics``（平台字体），字号从**同一份**解好的 `style` 取 ——
    /// 量宽度与排轨道必须对得上。
    func makeDanmakuRender(size: CGSize) -> DanmakuRenderPlan? {
        let lines = danmakuLines
        guard !lines.isEmpty, size.width > 1, size.height > 1 else {
            return nil
        }
        let style = danmakuDisplay.style.resolved(
            width: Double(size.width),
            height: Double(size.height)
        )
        let plan = DanmakuPlan(lines: lines, layout: style.layout) { line in
            AdaptiveFontMetrics.width(of: line.text, size: style.fontSize(of: line))
        }
        return DanmakuRenderPlan(plan: plan, style: style)
    }

    /// 现在该不该走表：只认 `playing` —— 暂停、缓冲、结束、失败都必须停住，
    /// 否则「缓冲时弹幕还在划」这种假象会让人以为卡的是弹幕而不是网。
    ///
    /// 弹幕与字幕共用它：两者都必须跟画面同一刻。
    func clockRate() -> Double {
        playerState == .playing ? playbackRate : 0
    }
}
