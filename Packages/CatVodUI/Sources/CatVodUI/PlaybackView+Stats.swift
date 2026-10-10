import CatVodPlayer
import SwiftUI

// 播放信息那一块：「播放信息」Section + 刷新 + 「引擎认不认这个协议」。
//
// 为什么放扩展文件：PlaybackView.swift 的文件长度（`file_length`）离 CI 的 error 线（800）只剩几十行；
// 这一块只读 `engine` / `playbackStats` 两个 @State，搬出来零成本（同 M11 拆 Emby、M23 拆下载那两次）。
// 代价：`engine` / `playbackStats` 从 `private` 放开到模块内 —— 跨文件扩展看不见 private（M04P19 踩过）。

extension PlaybackView {
    /// 「播放信息」：**只有报得出来的内核才显示**（MPV 与自研 FFmpeg 报得出）—— 与「轨道」同一口径，
    /// 拿不到就不显示，不放一排「未知」。
    ///
    /// 一行行照抄内核报的值，不做换算以外的加工：「设置里选了硬解、实际到底是不是硬解」
    /// 「看着不流畅，是丢帧还是网络」这类问题，屏幕上得有据可查。
    var statsSection: some View {
        Section("播放信息") {
            if let stats = playbackStats, !stats.isEmpty {
                statsRow("画面", stats.resolutionText)
                statsRow("容器", stats.fileFormat)
                statsRow("编码", stats.codecText)
                statsRow("帧率", stats.fpsText)
                statsRow("色彩", stats.dynamicRangeText)
                statsRow("输出", stats.outputText)
                statsRow("解码", stats.decodeText)
                statsRow("音频", stats.audioText)
                statsRow("码率", stats.bitrateText)
                statsRow("丢帧", stats.dropText)
            } else {
                Text("还没读到 —— 起播后点「刷新」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("刷新") {
                Task { await refreshPlaybackStats() }
            }
        }
    }

    /// 当前内核报不报得出播放信息（MPV 与自研 FFmpeg 认这个协议、系统内核认不了）—— 决定那一块显不显示。
    ///
    /// 用「引擎认不认这个协议」判，而不是写死 `kind == .mpv`：M04P13 自研 FFmpeg 接进来时
    /// 它同样认这个协议，界面这行一个字没改。
    var supportsPlaybackStats: Bool {
        guard let engine else {
            return false
        }
        return engine is PlaybackStatsProviding
    }

    /// 只画非空行（没读到的属性不占一行）。
    @ViewBuilder
    private func statsRow(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            InfoRow(title: title, value: value)
        }
    }

    /// 读一次播放信息：内核不支持就清空（那一块本来也不会显示）。
    ///
    /// 读到**非空**结果时回传给上层一次（M17P2）—— 诊断报告要用的就是这一份；
    /// 读不到东西（还没起播 / 属性没填上）不回传，免得把上一次的真实结果冲掉。
    func refreshPlaybackStats() async {
        guard let engine, let provider = engine as? PlaybackStatsProviding else {
            playbackStats = nil
            return
        }
        let stats = await provider.playbackStats()
        playbackStats = stats
        if !stats.isEmpty {
            onPlaybackStats?(stats)
        }
    }
}
