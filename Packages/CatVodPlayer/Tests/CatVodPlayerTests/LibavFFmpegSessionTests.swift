import AudioToolbox
@testable import CatVodPlayer
import CoreMedia
import CoreVideo
import Foundation
import Testing

/// 假渲染器：记下会话喂了什么（帧的时间戳 / 时长、play / pause 调用），背压可控。
final class FakeVideoRenderer: FFmpegVideoRendering, @unchecked Sendable {
    struct EnqueuedFrame: Equatable {
        var presentation: Double
        var duration: Double
    }

    struct ResetCall: Equatable {
        var seconds: Double
        var playing: Bool
        var rate: Float
    }

    private let lock = NSLock()
    private var frames: [EnqueuedFrame] = []
    private var playCalls = 0
    private var pauseCalls = 0
    private var lastRate: Float = 0
    private var ready = true
    private var seconds: Double = 0
    private var resets: [ResetCall] = []

    var enqueued: [EnqueuedFrame] {
        locked { frames }
    }

    var playCallCount: Int {
        locked { playCalls }
    }

    var pauseCallCount: Int {
        locked { pauseCalls }
    }

    var lastPlayRate: Float {
        locked { lastRate }
    }

    var isReadyForMoreMediaData: Bool {
        get { locked { ready } }
        set { locked { ready = newValue } }
    }

    var currentSeconds: Double {
        get { locked { seconds } }
        set { locked { seconds = newValue } }
    }

    var resetCalls: [ResetCall] {
        locked { resets }
    }

    @discardableResult
    func enqueue(pixelBuffer: CVPixelBuffer, presentationSeconds: Double, durationSeconds: Double) -> Bool {
        _ = pixelBuffer
        locked { frames.append(EnqueuedFrame(presentation: presentationSeconds, duration: durationSeconds)) }
        return true
    }

    func play(rate: Float) {
        locked {
            playCalls += 1
            lastRate = rate
        }
    }

    func pause() {
        locked { pauseCalls += 1 }
    }

    func flush() { }

    func reset(to seconds: Double, playing: Bool, rate: Float) {
        locked { resets.append(ResetCall(seconds: seconds, playing: playing, rate: rate)) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 假音频渲染器：记下喂了几块、每块的采样率、最后的音量，背压可控。
final class FakeAudioRenderer: FFmpegAudioRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var ready = true
    private var volume: Float = 1
    /// 喂进来的样本都带什么采样率 —— 换音轨测试拿它当「真的换了」的证据（M04P16）。
    private var rates: [Double] = []

    var enqueuedCount: Int {
        locked { samples }
    }

    var enqueuedSampleRates: [Double] {
        locked { rates }
    }

    var lastVolume: Float {
        locked { volume }
    }

    var isReadyForMoreMediaData: Bool {
        get { locked { ready } }
        set { locked { ready = newValue } }
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if let format = CMSampleBufferGetFormatDescription(sample),
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        {
            let rate = description.pointee.mSampleRate
            locked { rates.append(rate) }
        }
        locked { samples += 1 }
    }

    func flush() { }

    func setVolume(_ volume: Float) {
        locked { self.volume = volume }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 事件收集箱：会话的事件在解码线程上产出，单测用轮询读。
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FFmpegSessionEvent] = []

    func append(_ event: FFmpegSessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        items.append(event)
    }

    var all: [FFmpegSessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// 真会话（`LibavFFmpegSession`，M04P11 起音视频都接上）：真输入 + 真解码（硬解优先、软解兜底）+ 假渲染器。
///
/// 用 ``TinyMP4Fixture`` 现场编的小文件当片源（不打网络）；
/// 「画面 / 声音到底出没出」要等接线后上机看，这里钉的是**喂帧喂块语义与生命周期**。
@Suite("FFmpeg 真会话（M04P9/M04P11）")
struct LibavFFmpegSessionTests {
    /// 等条件成立（轮询 20ms）：超时就失败，不挂死。
    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeFixtureURL(audioSeconds: Double = 0, secondAudioSampleRate: Double = 0) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-session-\(UUID().uuidString).mp4")
        try await TinyMP4Fixture.write(
            to: url,
            width: 320,
            height: 240,
            fps: 30,
            frames: 30,
            audioSeconds: audioSeconds,
            secondAudioSampleRate: secondAudioSampleRate
        )
        return url
    }

    @Test("打不开的文件：报错误描述，不起线程")
    func openMissingFile() async {
        let session = LibavFFmpegSession(
            videoRenderer: FakeVideoRenderer(),
            audioRenderer: FakeAudioRenderer()
        )
        let failure = await session.open(
            MediaResource(url: "/definitely/not/here/\(UUID().uuidString).mp4"),
            decoderMode: .hardware
        )
        #expect(failure != nil)
        await session.close()
    }

    @Test("软解：也能播 —— sws 转 420v 后照常喂帧、播放信息如实写「软件解码」（M04P14）")
    func softwareDecodePath() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: FakeAudioRenderer())
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .software)
        #expect(failure == nil)

        let ended = await waitUntil { box.all.contains(.state(.ended)) }
        #expect(ended)
        #expect(renderer.enqueued.count == 30)

        // 「解码 / 输出」两行由第一帧实测：软解模式必须写软解，且输出是我们转的 420v
        let stats = await session.stats()
        #expect(stats.decodeText == "软件解码")
        #expect(stats.outputPixelFormat == "420v")
        await session.close()
    }

    @Test("换音轨：清单报两条；切到第二条之后喂来的样本换了采样率（M04P16）")
    func audioTrackSwitch() async throws {
        let url = try await makeFixtureURL(audioSeconds: 1.0, secondAudioSampleRate: 48000)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = FakeVideoRenderer()
        let audio = FakeAudioRenderer()
        let session = LibavFFmpegSession(videoRenderer: video, audioRenderer: audio)
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        func listedAudioTracks() -> [Int] {
            for event in box.all {
                if case let .tracks(_, audio, _) = event {
                    return audio
                }
            }
            return []
        }

        // 把解码循环先卡在背压上：一个包都还没读 —— 换轨发生在「有声音喂进来之前」，
        // 断言才不会跟解码速度赛跑（假渲染器的背压就是为这种事准备的）。
        video.isReadyForMoreMediaData = false
        let failure = await session.open(MediaResource(url: url.path), decoderMode: .software)
        #expect(failure == nil)

        // 1) 打开就报轨道清单：两条音频、没有字幕（我们还没有字幕轨）
        let listed = await waitUntil { listedAudioTracks().count == 2 }
        #expect(listed)
        let tracks = listedAudioTracks()
        let second = try #require(tracks.last)
        // 夹具没有字幕轨：清单里字幕是空数组（只报文本轨，M04P19）
        let subtitleLists = box.all.compactMap { event -> [Int]? in
            if case let .tracks(_, _, subtitle) = event {
                return subtitle
            }
            return nil
        }
        #expect(subtitleLists.first?.isEmpty == true)

        // 2) 切到第二条，等解码线程把请求取走（它卡在背压里也会先处理待办）
        await session.selectTrack(.index(second), for: .audio)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 3) 放行：喂来的样本应该是 48k（第二条轨道的采样率）—— 这就是「真的换了」的证据
        video.isReadyForMoreMediaData = true
        let heardSecond = await waitUntil(timeout: 4) { audio.enqueuedSampleRates.contains(48000) }
        #expect(heardSecond)
        #expect(!audio.enqueuedSampleRates.contains(44100))

        // 4) 播放信息按**当前**音轨报（两条都是 aac，这里顺手确认那一行没断）
        let stats = await session.stats()
        #expect(stats.audioCodec == "aac")
        await session.close()
    }

    @Test("端到端：视频帧与音频块都喂上、自动开播、EOF 报结束")
    func endToEnd() async throws {
        let url = try await makeFixtureURL(audioSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let audio = FakeAudioRenderer()
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: audio)
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)

        // 1 秒视频 + 1 秒音频的小文件：等它全喂完并报结束
        let ended = await waitUntil { box.all.contains(.state(.ended)) }
        #expect(ended)

        let frames = renderer.enqueued
        #expect(frames.count == 30)
        #expect(renderer.playCallCount == 1)
        #expect(renderer.lastPlayRate == 1)
        #expect(box.all.contains(.state(.playing)))
        // 音轨也接上：音频侧有块喂进来
        #expect(audio.enqueuedCount > 0)

        let first = try #require(frames.first)
        #expect(abs(first.presentation) < 0.001)
        let second = try #require(frames.dropFirst().first)
        #expect(abs(second.presentation - 1.0 / 30.0) < 0.002)
        // 逐帧时长 = 下一帧减上一帧
        for (current, next) in zip(frames, frames.dropFirst()) {
            #expect(abs(current.duration - (next.presentation - current.presentation)) < 0.002)
        }
        // 关字幕（M04P19）：没有内嵌轨时也该是安全的空操作
        await session.selectTrack(.disabled, for: .subtitle)

        // 播放信息那几行（M04P15）：解码实测 + 容器帧率（fixture 是 30fps）+ 输出像素格式
        let stats = await session.stats()
        #expect(stats.decodeText == "硬件解码（VideoToolbox）")
        #expect(abs(stats.fps - 30) < 0.5)
        #expect(!stats.outputPixelFormat.isEmpty)
        await session.close()
    }

    @Test("音量：透传给音频渲染器并夹到 0...1")
    func volumeForwarding() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = FakeAudioRenderer()
        let session = LibavFFmpegSession(videoRenderer: FakeVideoRenderer(), audioRenderer: audio)
        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)

        await session.setVolume(0.3)
        #expect(audio.lastVolume == 0.3)
        await session.setVolume(1.5)
        #expect(audio.lastVolume == 1)
        await session.close()
    }

    @Test("暂停 / 继续：渲染器跟着停 / 起，事件跟着报")
    func pauseAndResume() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: FakeAudioRenderer())
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        _ = await waitUntil { box.all.contains(.state(.playing)) }

        await session.pause()
        #expect(renderer.pauseCallCount == 1)
        // 事件是异步消费的：等它进箱子，别跟消费任务抢时间（M04P9 首轮就是这么红的）
        let paused = await waitUntil { box.all.contains(.state(.paused)) }
        #expect(paused)

        await session.play()
        #expect(renderer.playCallCount == 2)
        await session.close()
    }

    @Test("seek：立刻回执、清队重定位、重新读回还能再播到结束")
    func seeksBackAndReplays() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: FakeAudioRenderer())
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        let endedOnce = await waitUntil { box.all.contains(.state(.ended)) }
        #expect(endedOnce)
        let framesBefore = renderer.enqueued.count
        #expect(framesBefore == 30)

        await session.seek(to: 0)
        // 回执立刻发（控制线程做的，不依赖解码循环）
        let echoed = await waitUntil {
            box.all.contains { event in
                if case let .time(current, _) = event {
                    return current == 0
                }
                return false
            }
        }
        #expect(echoed)
        // 解码线程接上：清队重定位（此时还在播）
        let reset = await waitUntil { !renderer.resetCalls.isEmpty }
        #expect(reset)
        #expect(renderer.resetCalls.first?.seconds == 0)
        #expect(renderer.resetCalls.first?.playing == true)

        // 重新读回、再次播到结束（ended 事件出现两次）
        let endedTwice = await waitUntil {
            box.all.filter { $0 == .state(.ended) }.count >= 2
        }
        #expect(endedTwice)
        #expect(renderer.enqueued.count > framesBefore)
        await session.close()
    }

    @Test("背压：视频渲染器说吃不下就先不解，一放开立刻继续")
    func backpressure() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        renderer.isReadyForMoreMediaData = false
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: FakeAudioRenderer())

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(renderer.enqueued.isEmpty)

        renderer.isReadyForMoreMediaData = true
        let fed = await waitUntil { !renderer.enqueued.isEmpty }
        #expect(fed)
        await session.close()
    }

    @Test("close：幂等；关掉之后不再见新帧")
    func closeStopsWork() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        renderer.isReadyForMoreMediaData = false // 让它停在「等背压」时被关掉
        let session = LibavFFmpegSession(videoRenderer: renderer, audioRenderer: FakeAudioRenderer())

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        await session.close()
        await session.close()

        renderer.isReadyForMoreMediaData = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(renderer.enqueued.isEmpty)
    }
}
