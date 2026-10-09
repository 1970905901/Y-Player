@testable import CatVodPlayer
import Foundation
import Testing

/// 播放信息（M4 前置）：mpv 报回来的那串属性 → 屏幕上那几行人话。
@Suite("播放信息：属性到文案")
struct PlaybackStatsTests {
    @Test("4K HEVC HDR10 + 硬解：每一项都拼对")
    func hdr10WithHardwareDecode() {
        let stats = PlaybackStats(rawValues: [
            "video-params/w": "3840",
            "video-params/h": "2160",
            "video-format": "hevc",
            "video-params/pixelformat": "yuv420p10",
            "container-fps": "23.976000",
            "video-params/primaries": "bt.2020",
            "video-params/gamma": "pq",
            "hwdec-current": "videotoolbox",
            "video-bitrate": "12400000",
            "frame-drop-count": "0",
            "decoder-frame-drop-count": "0",
        ])
        #expect(stats.resolutionText == "3840×2160")
        #expect(stats.codecText == "hevc · yuv420p10")
        #expect(stats.fpsText == "23.976")
        #expect(stats.isHDR)
        #expect(stats.dynamicRangeText == "HDR · PQ (ST2084) · BT.2020")
        #expect(stats.decodeText == "硬件解码（VideoToolbox）")
        #expect(stats.bitrateText == "12.4 Mbps")
        #expect(stats.dropText == "无丢帧")
    }

    @Test("HLG 也算 HDR")
    func hlgIsHDR() {
        let stats = PlaybackStats(rawValues: [
            "video-params/gamma": "hlg",
            "video-params/primaries": "bt.2020",
        ])
        #expect(stats.isHDR)
        #expect(stats.dynamicRangeText == "HDR · HLG · BT.2020")
    }

    @Test("片源是 HDR、输出被压成 SDR：两个都要说出来（M4 要的就是这一对）")
    func outputMayDifferFromSource() {
        let stats = PlaybackStats(rawValues: [
            "video-params/primaries": "bt.2020",
            "video-params/gamma": "pq",
            "video-out-params/primaries": "bt.709",
            "video-out-params/gamma": "bt.1886",
            "video-out-params/pixelformat": "yuv420p",
        ])
        #expect(stats.dynamicRangeText == "HDR · PQ (ST2084) · BT.2020")
        #expect(stats.outputText == "SDR · BT.1886 · BT.709 · yuv420p")
        #expect(stats.isOutputHDR == false)
        #expect(stats.isHDR)
    }

    @Test("输出侧没读到：不许猜（`isOutputHDR` 给 nil、那一行给空串）")
    func missingOutputStaysUnknown() {
        let stats = PlaybackStats(rawValues: ["video-params/gamma": "pq", "video-params/primaries": "bt.2020"])
        #expect(stats.outputText.isEmpty)
        #expect(stats.isOutputHDR == nil)
        #expect(stats.isHDR)
    }

    @Test("BT.2020 + BT.1886 是 10bit SDR —— 不许按色域判成 HDR")
    func wideGamutSDRIsNotHDR() {
        let stats = PlaybackStats(rawValues: [
            "video-params/primaries": "bt.2020",
            "video-params/gamma": "bt.1886",
        ])
        #expect(!stats.isHDR)
        #expect(stats.dynamicRangeText == "SDR · BT.1886 · BT.2020")
    }

    @Test("软解 / 硬解：只看实际生效的 hwdec-current")
    func decodeMode() {
        let software = PlaybackStats(rawValues: ["hwdec-current": "no"])
        #expect(software.decodeText == "软件解码")

        let hardware = PlaybackStats(rawValues: ["hwdec-current": "videotoolbox"])
        #expect(hardware.decodeText == "硬件解码（VideoToolbox）")

        // 还没起播：属性是空的 —— 这一行不该显示（空串）
        #expect(PlaybackStats().decodeText.isEmpty)
    }

    @Test("丢帧：两边都数得清，0 就明说无丢帧")
    func droppedFrames() {
        let none = PlaybackStats(rawValues: ["frame-drop-count": "0", "decoder-frame-drop-count": "0"])
        #expect(none.dropText == "无丢帧")

        let some = PlaybackStats(rawValues: ["frame-drop-count": "3", "decoder-frame-drop-count": "1"])
        #expect(some.dropText == "显示 3 · 解码 1")
    }

    @Test("缺字段：缺什么空什么，不编默认值")
    func missingFieldsStayEmpty() {
        let stats = PlaybackStats(rawValues: ["video-params/w": "1920", "video-params/h": "1080"])
        #expect(stats.resolutionText == "1920×1080")
        #expect(stats.codecText.isEmpty)
        #expect(stats.fpsText.isEmpty)
        #expect(stats.dynamicRangeText.isEmpty)
        #expect(stats.decodeText.isEmpty)
        #expect(stats.bitrateText.isEmpty)
        #expect(!stats.isEmpty)

        #expect(PlaybackStats().isEmpty)
    }

    @Test("数值格式：整数帧率不带小数点、低码率走 kbps、脏值当没读到")
    func numberFormatting() {
        #expect(PlaybackStats(rawValues: ["container-fps": "24.000"]).fpsText == "24")
        #expect(PlaybackStats(rawValues: ["container-fps": "29.970"]).fpsText == "29.97")
        #expect(PlaybackStats(rawValues: ["video-bitrate": "800000"]).bitrateText == "800 kbps")
        #expect(PlaybackStats(rawValues: ["video-bitrate": "0"]).bitrateText.isEmpty)

        // 前后空白照收，读不出来的当没读到
        #expect(PlaybackStats(rawValues: ["video-params/w": " 1280 "]).videoWidth == 1280)
        #expect(PlaybackStats(rawValues: ["video-params/w": "abc"]).videoWidth == 0)
    }

    @Test("认不出来的色彩名原样输出，不猜")
    func unknownColorNames() {
        let stats = PlaybackStats(rawValues: ["video-params/gamma": "some-new-transfer"])
        #expect(stats.dynamicRangeText == "SDR · some-new-transfer")
    }
}
