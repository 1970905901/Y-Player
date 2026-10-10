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
    /// 让接下来 N 次 `enqueue` 返回 false（模拟「这一帧没能进显示层」，M04P22 的显示侧丢帧）。
    private var enqueueFailures = 0
    /// 步进（M04P23）：调用次数与答案（真实现在渲染器里挑「下一帧的 pts」，假实现只记账）。
    private var stepCalls = 0
    private var stepSucceeds = true

    var enqueueFailuresRemaining: Int {
        get { locked { enqueueFailures } }
        set { locked { enqueueFailures = newValue } }
    }

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

    /// 逐帧步进（M04P23）：调了几次、给什么答案（默认「有下一帧」）。
    var stepCallCount: Int {
        locked { stepCalls }
    }

    var canStepToNextFrame: Bool {
        get { locked { stepSucceeds } }
        set { locked { stepSucceeds = newValue } }
    }

    @discardableResult
    func enqueue(pixelBuffer: CVPixelBuffer, presentationSeconds: Double, durationSeconds: Double) -> Bool {
        _ = pixelBuffer
        var accepted = true
        locked {
            if enqueueFailures > 0 {
                enqueueFailures -= 1
                accepted = false
            } else {
                frames.append(EnqueuedFrame(presentation: presentationSeconds, duration: durationSeconds))
            }
        }
        return accepted
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

    func stepToNextFrame() -> Bool {
        locked {
            stepCalls += 1
            return stepSucceeds
        }
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
    /// 每块样本的峰值 —— 增益测试拿它当「真被放大了」的证据（M04P23）。
    private var peakValues: [Float] = []

    var enqueuedCount: Int {
        locked { samples }
    }

    var enqueuedSampleRates: [Double] {
        locked { rates }
    }

    var peaks: [Float] {
        locked { peakValues }
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
        let peak = TinyMP4Fixture.peak(of: sample)
        locked {
            samples += 1
            peakValues.append(peak)
        }
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

    private func makeFixtureURL(
        audioSeconds: Double = 0,
        secondAudioSampleRate: Double = 0,
        toneAmplitude: Double = 0
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-session-\(UUID().uuidString).mp4")
        try await TinyMP4Fixture.write(
            to: url,
            width: 320,
            height: 240,
            fps: 30,
            frames: 30,
            audioSeconds: audioSeconds,
            secondAudioSampleRate: secondAudioSampleRate,
            toneAmplitude: toneAmplitude
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

        func listedAudioTracks() -> [PlayerTrack] {
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

        // 1) 打开就报轨道清单：两条音频、没有字幕（夹具没造字幕轨）
        let listed = await waitUntil { listedAudioTracks().count == 2 }
        #expect(listed)
        let tracks = listedAudioTracks()
        let second = try #require(tracks.last)
        // 夹具没有字幕轨：清单里字幕是空数组（只报文本轨，M04P19）
        let subtitleLists = box.all.compactMap { event -> [PlayerTrack]? in
            if case let .tracks(_, _, subtitle) = event {
                return subtitle
            }
            return nil
        }
        #expect(subtitleLists.first?.isEmpty == true)

        // 2) 切到第二条，等解码线程把请求取走（它卡在背压里也会先处理待办）。
        //    顺便把「显示位置」定在 0.5s：换完要按它重定位（M04P22）。
        video.currentSeconds = 0.5
        await session.selectTrack(.index(second.id), for: .audio)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let repositioned = video.resetCalls.contains { abs($0.seconds - 0.5) < 0.001 }
        #expect(repositioned)

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

    @Test("显示侧丢帧（M04P22）：帧没能进显示层时，播放信息那行报得出来")
    func displaySideDropsAreReported() async throws {
        let url = try await makeFixtureURL(audioSeconds: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = FakeVideoRenderer()
        let audio = FakeAudioRenderer()
        let session = LibavFFmpegSession(videoRenderer: video, audioRenderer: audio)
        // 头一帧的样本转换故意失败一次 —— 就是「这一帧没能进显示层」。
        video.enqueueFailuresRemaining = 1

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .software)
        #expect(failure == nil)
        let playedEnough = await waitUntil { video.enqueued.count >= 20 }
        #expect(playedEnough)

        let stats = await session.stats()
        #expect(stats.dropText == "显示 1 · 解码 0")
        await session.close()
    }

    @Test("暂停时 seek：喂帧不许把播放按回去（M04P22 顺手修的老账）")
    func seekWhilePausedDoesNotResume() async throws {
        let url = try await makeFixtureURL(audioSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = FakeVideoRenderer()
        let audio = FakeAudioRenderer()
        let session = LibavFFmpegSession(videoRenderer: video, audioRenderer: audio)
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .software)
        #expect(failure == nil)
        let started = await waitUntil { video.playCallCount > 0 }
        #expect(started)

        await session.pause()
        let playsBefore = video.playCallCount
        let playingEventsBefore = box.all.filter { $0 == .state(.playing) }.count

        await session.seek(to: 0.2)
        let repositioned = await waitUntil { video.resetCalls.contains { abs($0.seconds - 0.2) < 0.001 } }
        #expect(repositioned)
        // 给解码线程一点时间把跳转后的帧喂进来 —— 老代码就是在这时把暂停按回播放的。
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(video.playCallCount == playsBefore)
        #expect(box.all.filter { $0 == .state(.playing) }.count == playingEventsBefore)
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

    @Test("逐帧步进（M04P23）：播放中调用 = 先暂停再走一帧；没有下一帧也如实报暂停")
    func stepFramePausesAndAdvances() async throws {
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
        let playing = await waitUntil { box.all.contains(.state(.playing)) }
        #expect(playing)

        // 播放中直接点「步进」：内核先暂停，再让渲染器把时间轴挪到下一帧
        await session.stepFrame()
        let paused = await waitUntil { box.all.contains(.state(.paused)) }
        #expect(paused)
        #expect(renderer.stepCallCount == 1)

        // 队里没有下一帧（渲染器说没有）：照样报暂停，但就停在原地（不假装走了）
        renderer.canStepToNextFrame = false
        await session.stepFrame()
        let pausedAgain = await waitUntil {
            box.all.filter { $0 == .state(.paused) }.count >= 2
        }
        #expect(pausedAgain)
        #expect(renderer.stepCallCount == 2)

        // 步进没有把链路卡死：还能继续播
        await session.play()
        #expect(renderer.playCallCount >= 2)
        await session.close()
    }

    @Test("音频增益（M04P23）：写了 2 倍之后喂来的样本真被放大（会话把增益抄给了解码器）")
    func audioGainReachesDecoder() async throws {
        let url = try await makeFixtureURL(audioSeconds: 1.0, toneAmplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = FakeVideoRenderer()
        let audio = FakeAudioRenderer()
        // 先把解码循环卡在背压上：一个包都别读 —— 增益要在「第一块喂出来」之前写好，
        // 断言才不用跟解码速度赛跑（假渲染器的背压就是为这种事准备的）。
        video.isReadyForMoreMediaData = false
        let session = LibavFFmpegSession(videoRenderer: video, audioRenderer: audio)
        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        await session.setAudioGain(2)
        video.isReadyForMoreMediaData = true

        let heard = await waitUntil(timeout: 4) { !audio.peaks.isEmpty }
        #expect(heard)
        // 源峰值 0.5 左右；乘 2 → 夹到 1 —— 最响的一块 > 0.85 就说明增益真的上车了
        let loudest = audio.peaks.max() ?? 0
        #expect(loudest > 0.85)
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
