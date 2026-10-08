@testable import CatVodNet
@testable import CatVodUI
import Testing

/// 「已跳过广告」的提示文案（M06k）。
///
/// 这句话会在播放页反复出现，写错的代价比不显示更大：0 段也弹（噪音）、
/// 秒数四舍五入成 0 还硬写「约 0 秒」、把「处理过几个清单」当成「跳过几次」。
@Suite("跳过广告提示文案")
struct AdSkipNoticeTests {
    @Test("没跳过任何东西：返回空串（界面据此不显示这一行）")
    func emptyWithoutRemoval() {
        #expect(AdSkipNotice.text(for: AdSkipRecorder.Stats()).isEmpty)
        #expect(AdSkipNotice.text(for: AdSkipRecorder.Stats(playlists: 9, cleanedPlaylists: 0)).isEmpty)
    }

    @Test("跳过了：写清段数；时长不足 1 秒就不提秒数")
    func formatsCountAndDuration() {
        #expect(AdSkipNotice.text(for: AdSkipRecorder.Stats(
            cleanedPlaylists: 1,
            removedSegments: 1,
            removedDurationSec: 7
        ))
            == "已跳过广告 1 段，约 7 秒")
        #expect(AdSkipNotice.text(for: AdSkipRecorder.Stats(
            cleanedPlaylists: 2,
            removedSegments: 3,
            removedDurationSec: 0.4
        ))
            == "已跳过广告 3 段")
        #expect(AdSkipNotice.text(for: AdSkipRecorder.Stats(
            cleanedPlaylists: 1,
            removedSegments: 2,
            removedDurationSec: 12.6
        ))
            == "已跳过广告 2 段，约 13 秒")
    }
}
