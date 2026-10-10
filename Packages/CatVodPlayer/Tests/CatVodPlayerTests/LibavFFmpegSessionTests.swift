@testable import CatVodPlayer
import CoreVideo
import Foundation
import Testing

/// 假渲染器：记下会话喂了什么（帧的时间戳 / 时长、play / pause 调用），背压可控。
final class FakeVideoRenderer: FFmpegVideoRendering, @unchecked Sendable {
    struct EnqueuedFrame: Equatable {
        var presentation: Double
        var duration: Double
    }

    private let lock = NSLock()
    private var frames: [EnqueuedFrame] = []
    private var playCalls = 0
    private var pauseCalls = 0
    private var lastRate: Float = 0
    private var ready = true
    private var seconds: Double = 0

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

/// 真会话（`LibavFFmpegSession`，M04P9）：真输入 + 真 VT 解码 + 假渲染器。
///
/// 用 ``TinyMP4Fixture`` 现场编的小文件当片源（不打网络）；
/// 「画面到底出没出」要等接线后上机看，这里钉的是**喂帧语义与生命周期**。
@Suite("FFmpeg 真会话（M04P9）")
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

    private func makeFixtureURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-session-\(UUID().uuidString).mp4")
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30)
        return url
    }

    @Test("打不开的文件：报错误描述，不起线程")
    func openMissingFile() async {
        let session = LibavFFmpegSession(renderer: FakeVideoRenderer())
        let failure = await session.open(
            MediaResource(url: "/definitely/not/here/\(UUID().uuidString).mp4"),
            decoderMode: .hardware
        )
        #expect(failure != nil)
        await session.close()
    }

    @Test("软解：明确拒绝，不假装生效")
    func softwareDecoderRejected() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = LibavFFmpegSession(renderer: FakeVideoRenderer())
        let failure = await session.open(MediaResource(url: url.path), decoderMode: .software)
        #expect(failure != nil)
        #expect(failure?.contains("硬解") == true)
        await session.close()
    }

    @Test("端到端：整个小文件全解出来、按显示时间排队、自动开播、EOF 报结束")
    func endToEnd() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let session = LibavFFmpegSession(renderer: renderer)
        let box = EventBox()
        let consumer = Task { for await event in session.events {
            box.append(event)
        } }
        defer { consumer.cancel() }

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)

        // 30 帧小文件：等它全喂完并报结束
        let ended = await waitUntil { box.all.contains(.state(.ended)) }
        #expect(ended)

        let frames = renderer.enqueued
        #expect(frames.count == 30)
        #expect(renderer.playCallCount == 1)
        #expect(renderer.lastPlayRate == 1)
        #expect(box.all.contains(.state(.playing)))

        let first = try #require(frames.first)
        #expect(abs(first.presentation) < 0.001)
        let second = try #require(frames.dropFirst().first)
        #expect(abs(second.presentation - 1.0 / 30.0) < 0.002)
        // 逐帧时长 = 下一帧减上一帧
        for (current, next) in zip(frames, frames.dropFirst()) {
            #expect(abs(current.duration - (next.presentation - current.presentation)) < 0.002)
        }
        await session.close()
    }

    @Test("暂停 / 继续：渲染器跟着停 / 起，事件跟着报")
    func pauseAndResume() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        let session = LibavFFmpegSession(renderer: renderer)
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
        #expect(box.all.contains(.state(.paused)))

        await session.play()
        #expect(renderer.playCallCount == 2)
        await session.close()
    }

    @Test("背压：渲染器说吃不下就先不解，一放开立刻继续")
    func backpressure() async throws {
        let url = try await makeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = FakeVideoRenderer()
        renderer.isReadyForMoreMediaData = false
        let session = LibavFFmpegSession(renderer: renderer)

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
        let session = LibavFFmpegSession(renderer: renderer)

        let failure = await session.open(MediaResource(url: url.path), decoderMode: .hardware)
        #expect(failure == nil)
        await session.close()
        await session.close()

        renderer.isReadyForMoreMediaData = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(renderer.enqueued.isEmpty)
    }
}
