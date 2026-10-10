import AVFoundation
@testable import CatVodPlayer
import Testing

/// 系统内核的轨道上报与选择（M03P7）。
///
/// CI 限制（与 `SystemPlayerRateTests` 同一条理由）：跑测试的机器上没有带多音轨/内封字幕的媒体，
/// `AVMediaSelectionGroup` 拿不到真数据，所以「能选出几条轨」只能在真机/模拟器上人工确认。
/// 这里钉住**没有媒体时的行为**：不崩、列表为空、选择是安全的空操作。
@MainActor
@Suite("系统内核：轨道（无媒体时的边界）")
struct SystemPlayerTracksTests {
    @Test("没有条目时：三个类别都没有可选项")
    func trackListEmptyWithoutItem() {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        let tracks = engine.trackList()
        #expect(tracks.video.isEmpty)
        #expect(tracks.audio.isEmpty)
        #expect(tracks.subtitle.isEmpty)
        #expect(engine.selectionGroup(for: .audio) == nil)
    }

    @Test("没有条目时选轨道：安全返回，不崩")
    func selectionWithoutItemIsSafe() async {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        await engine.selectTrack(.index(1), for: .audio)
        await engine.selectTrack(.disabled, for: .subtitle)
        await engine.selectTrack(.auto, for: .video)
        // 越界下标同样只是不做（`options` 为空）。
        await engine.selectTrack(.index(99), for: .audio)
    }
}
