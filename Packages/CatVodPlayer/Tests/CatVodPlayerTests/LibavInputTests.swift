@testable import CatVodPlayer
import Foundation
import Testing

/// 自研内核的输入层（M04P6）：打开 → 读流信息 → 关。
///
/// 真网络流不进单测（红绿看运气）；用 ``TinyMP4Fixture`` 现场编出来的小文件当输入。
@Suite("Libav 输入层（M04P6）")
struct LibavInputTests {
    @Test("headers → FFmpeg http 选项：UA / Referer 走专名，其余拼串")
    func headerOptions() {
        let options = LibavInput.httpOptions(from: [
            "User-Agent": "YPlayer/1.0",
            "Referer": "https://example.com",
            "X-Token": "abc",
            "Accept": "*/*",
        ])
        #expect(options["user_agent"] == "YPlayer/1.0")
        #expect(options["referer"] == "https://example.com")
        #expect(options["headers"] == "Accept: */*\r\nX-Token: abc")
        #expect(options.count == 3)

        #expect(LibavInput.httpOptions(from: [:]).isEmpty)
        // 头名大小写不敏感：小写 user-agent 也走专名选项
        #expect(LibavInput.httpOptions(from: ["user-agent": "x"])["user_agent"] == "x")
    }

    @Test("打开不存在的文件：给错误描述，不崩；没打开时读不到信息；close 幂等")
    func openMissingFile() {
        let input = LibavInput()
        #expect(input.mediaInfo() == nil)

        let failure = input.open(url: "/definitely/not/here/\(UUID().uuidString).mp4", headers: [:])
        #expect(failure != nil)
        #expect(input.mediaInfo() == nil)

        input.close()
        input.close()
    }

    @Test("打开真实小文件：时长 / 视频流 / 分辨率 / 编码名")
    func openTinyFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libavinput-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        let failure = input.open(url: url.path, headers: [:])
        #expect(failure == nil)

        let info = try #require(input.mediaInfo())
        #expect(abs(info.durationSeconds - 1.0) < 0.3)
        #expect(info.streams.count == 1)
        let videos = info.streams.filter { $0.kind == .video }
        let video = try #require(videos.first)
        #expect(video.width == 320)
        #expect(video.height == 240)
        #expect(video.codecName == "h264")
    }

    @Test("帧率与色彩翻译：只认能确证的，认不出给空串")
    func fpsAndColorNames() {
        #expect(LibavInput.fps(numerator: 30, denominator: 1) == 30)
        #expect(LibavInput.fps(numerator: 24000, denominator: 1001) > 23.97)
        #expect(LibavInput.fps(numerator: 0, denominator: 0) == 0)
        #expect(LibavInput.fps(numerator: 30, denominator: 0) == 0)

        // 括号里的数字是 FFmpeg 的枚举值（测试目标不 import Libavutil，写在这儿核对）
        #expect(LibavInput.colorPrimariesName(1) == "bt.709") // AVCOL_PRI_BT709
        #expect(LibavInput.colorPrimariesName(9) == "bt.2020") // AVCOL_PRI_BT2020
        #expect(LibavInput.colorPrimariesName(12) == "display-p3") // AVCOL_PRI_SMPTE432
        #expect(LibavInput.colorPrimariesName(6) == "bt.601") // AVCOL_PRI_SMPTE170M
        #expect(LibavInput.colorPrimariesName(2).isEmpty) // AVCOL_PRI_UNSPECIFIED：不猜

        #expect(LibavInput.colorTransferName(16) == "pq") // AVCOL_TRC_SMPTE2084（HDR）
        #expect(LibavInput.colorTransferName(18) == "hlg") // AVCOL_TRC_ARIB_STD_B67（HDR）
        #expect(LibavInput.colorTransferName(1) == "bt.709") // AVCOL_TRC_BT709
        #expect(LibavInput.colorTransferName(4) == "bt.470m") // AVCOL_TRC_GAMMA22
        #expect(LibavInput.colorTransferName(2).isEmpty) // AVCOL_TRC_UNSPECIFIED
    }

    @Test("nextPacket：包按流下标读出，读到尾 isAtEnd 标上（统一 demux 的入口）")
    func readsPackets() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("packets-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)

        var count = 0
        while let packet = input.nextPacket() {
            #expect(packet.streamIndex == 0)
            count += 1
        }
        #expect(input.isAtEnd)
        #expect(count >= 30)
    }

    @Test("seek：读到尾后跳回起点还能再读，isAtEnd 复位")
    func seeksBackToStart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)

        let input = LibavInput()
        defer { input.close() }
        #expect(input.open(url: url.path, headers: [:]) == nil)

        var first = 0
        while input.nextPacket() != nil {
            first += 1
        }
        #expect(input.isAtEnd)
        #expect(first >= 30)

        #expect(input.seek(to: 0) == nil)
        #expect(!input.isAtEnd)
        var second = 0
        while input.nextPacket() != nil {
            second += 1
        }
        #expect(second >= 25)
    }
}
