import AVFoundation
@testable import CatVodPlayer
import Foundation
import Testing

/// 画面比例（M03P9）：支持矩阵、mpv 三条属性、自研内核的 gravity 映射，以及引擎真的下命令。
@Suite("画面比例")
struct PlaybackScaleModeTests {
    @Test("支持矩阵：MPV 全支持；自研 FFmpeg 只有 gravity 三态；系统内核没有这个能力")
    func supportMatrix() {
        #expect(PlaybackScaleMode.supportedModes(by: .mpv) == PlaybackScaleMode.allCases)
        #expect(PlaybackScaleMode.supportedModes(by: .ffmpeg) == [.fit, .crop, .stretch])
        #expect(PlaybackScaleMode.supportedModes(by: .system).isEmpty)
    }

    @Test("从存档串还原：认得出就用，空串 / 认不出回落「适应」（M03P19）")
    func decodeArchive() {
        #expect(PlaybackScaleMode.decode("crop") == .crop)
        #expect(PlaybackScaleMode.decode("ratio4x3") == .ratio4x3)
        #expect(PlaybackScaleMode.decode("") == .fit)
        #expect(PlaybackScaleMode.decode(nil) == .fit)
        #expect(PlaybackScaleMode.decode("zoom-in") == .fit)
        // 每一档都能往返（存档位就是 rawValue）
        for mode in PlaybackScaleMode.allCases {
            #expect(PlaybackScaleMode.decode(mode.rawValue) == mode)
        }
    }

    @Test("档位文案：名字本身就是语义（参考实现的具体档位表没拿到，不猜）")
    func displayNames() {
        #expect(PlaybackScaleMode.fit.displayName == "适应")
        #expect(PlaybackScaleMode.ratio16x9.displayName == "16:9")
        #expect(PlaybackScaleMode.ratio4x3.displayName == "4:3")
        #expect(PlaybackScaleMode.crop.displayName == "裁剪铺满")
        #expect(PlaybackScaleMode.stretch.displayName == "拉伸铺满")
    }

    @Test("mpv：每一档都把三条属性设一遍（不留上一档的残留）")
    func mpvCommands() {
        for mode in PlaybackScaleMode.allCases {
            let commands = mode.mpvCommands
            #expect(commands.count == 3)
            #expect(commands.map { $0[1] } == ["video-aspect-override", "panscan", "keepaspect"])
            #expect(commands.allSatisfy { $0.count == 3 && $0[0] == "set" })
        }
        // 抽查几条关键值：16:9 只改比例；裁剪 = panscan 1 且仍保比例；拉伸 = keepaspect no。
        #expect(PlaybackScaleMode.ratio16x9.mpvCommands[0] == ["set", "video-aspect-override", "16:9"])
        #expect(PlaybackScaleMode.crop.mpvCommands[1] == ["set", "panscan", "1.0"])
        #expect(PlaybackScaleMode.crop.mpvCommands[2] == ["set", "keepaspect", "yes"])
        #expect(PlaybackScaleMode.stretch.mpvCommands[2] == ["set", "keepaspect", "no"])
        #expect(PlaybackScaleMode.fit.mpvCommands[0] == ["set", "video-aspect-override", "no"])
    }

    @Test("自研 FFmpeg：gravity 三态；16:9 / 4:3 映射不出来（nil，不静默改成适应）")
    func avGravity() {
        #expect(PlaybackScaleMode.fit.avVideoGravity == .resizeAspect)
        #expect(PlaybackScaleMode.crop.avVideoGravity == .resizeAspectFill)
        #expect(PlaybackScaleMode.stretch.avVideoGravity == .resize)
        #expect(PlaybackScaleMode.ratio16x9.avVideoGravity == nil)
        #expect(PlaybackScaleMode.ratio4x3.avVideoGravity == nil)
    }

    @Test("自研内核的画面层：设一档就落到 videoGravity；映射不出来的档位保持原样")
    func surfaceAppliesGravity() {
        let surface = FFmpegVideoSurface()
        surface.setScaleMode(.crop)
        #expect(surface.layer.videoGravity == .resizeAspectFill)
        surface.setScaleMode(.stretch)
        #expect(surface.layer.videoGravity == .resize)
        // 16:9 表达不了：不动它（不静默改成「适应」）。
        surface.setScaleMode(.ratio16x9)
        #expect(surface.layer.videoGravity == .resize)
    }

    @Test("MPV 引擎：load 之后 setScaleMode 真的把命令下给会话")
    func engineAppliesScale() async throws {
        let session = FakeMpvSession()
        let engine = MpvEngine(decoderMode: .hardware, makeSession: { session })
        try await engine.load(MediaResource(url: "https://example.com/live.m3u8"))

        await engine.setScaleMode(.crop)

        let commands = session.commands
        #expect(commands.contains(["set", "video-aspect-override", "no"]))
        #expect(commands.contains(["set", "panscan", "1.0"]))
        #expect(commands.contains(["set", "keepaspect", "yes"]))
    }

    @Test("MPV 引擎：还没 load（没有会话）时 setScaleMode 是安全空操作")
    func engineWithoutSessionIsSafe() async {
        let engine = MpvEngine(decoderMode: .hardware, makeSession: { nil })
        await engine.setScaleMode(.stretch)
        // Swift Testing 的宏参数里不写 await（本仓库踩过）：先落局部再断言。
        let state = await engine.currentState()
        #expect(state == .idle)
    }
}
