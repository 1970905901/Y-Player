import AVFoundation
@testable import CatVodPlayer
import CoreMedia
import CoreVideo
import Foundation

/// 生成一个几帧的小 MP4（测试夹具）：给输入层 / demux 类测试一个**离线的确定性输入**。
///
/// 为什么不用真网络流：单测打网络 = 红绿看运气。这个夹具用 AVAssetWriter 现场编出来，
/// M04P7 的 demux 测试可以接着用。
enum TinyMP4Fixture {
    /// 写一个 `frames` 帧（`fps` 帧率）、黑/灰交替的 H.264 MP4；
    /// `audioSeconds > 0` 时再加一条等长的 AAC 静音音轨（M04P10 起）；
    /// `secondAudioSampleRate > 0` 时再加**第二条**不同采样率的音轨（M04P16 换轨测试用
    /// —— 换过去之后，喂来的样本采样率会变，那就是「真的换了」的证据）。
    ///
    /// 失败原因都带着走（writer.error 优先），别让调用方对着一个空文件猜。
    static func write(
        to url: URL,
        width: Int = 320,
        height: Int = 240,
        fps: Int = 30,
        frames: Int = 30,
        audioSeconds: Double = 0,
        secondAudioSampleRate: Double = 0
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        let audioInput: AVAssetWriterInput?
        let secondAudioInput: AVAssetWriterInput?
        if audioSeconds > 0 {
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64000,
            ])
            candidate.expectsMediaDataInRealTime = false
            guard writer.canAdd(candidate) else {
                throw FixtureError.writerRejectedInput
            }
            writer.add(candidate)
            audioInput = candidate
            if secondAudioSampleRate > 0 {
                let second = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: secondAudioSampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 64000,
                ])
                second.expectsMediaDataInRealTime = false
                guard writer.canAdd(second) else {
                    throw FixtureError.writerRejectedInput
                }
                writer.add(second)
                secondAudioInput = second
            } else {
                secondAudioInput = nil
            }
        } else {
            audioInput = nil
            secondAudioInput = nil
        }
        guard writer.canAdd(input) else {
            throw FixtureError.writerRejectedInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? FixtureError.startFailed
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw FixtureError.noPixelBufferPool
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer
            else {
                throw FixtureError.noPixelBuffer
            }
            fill(pixelBuffer, gray: frame % 2 == 0 ? 32 : 200)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? FixtureError.appendFailed
            }
        }

        input.markAsFinished()
        if let audioInput, audioSeconds > 0 {
            try await appendSilence(to: audioInput, seconds: audioSeconds)
            audioInput.markAsFinished()
        }
        if let secondAudioInput, audioSeconds > 0, secondAudioSampleRate > 0 {
            try await appendSilence(
                to: secondAudioInput,
                seconds: audioSeconds,
                sampleRate: secondAudioSampleRate
            )
            secondAudioInput.markAsFinished()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.finishFailed
        }
    }

    /// 往音轨写静音：LPCM 块（复用 `LibavAudioSampleBuffer` 的封装）→ writer input 自己编 AAC。
    private static func appendSilence(
        to input: AVAssetWriterInput,
        seconds: Double,
        sampleRate: Double = 44100,
        channels: Int = 2
    ) async throws {
        let chunkFrames = 1024
        let totalFrames = Int(seconds * sampleRate)
        var written = 0
        while written < totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let frames = min(chunkFrames, totalFrames - written)
            let byteCount = frames * channels * MemoryLayout<Float>.size
            guard let raw = malloc(byteCount) else {
                throw FixtureError.noAudioBuffer
            }
            memset(raw, 0, byteCount)
            guard let sample = LibavAudioSampleBuffer.make(
                ownedPCM: raw,
                frameCount: frames,
                sampleRate: sampleRate,
                channels: channels,
                presentationSeconds: Double(written) / sampleRate
            ), input.append(sample) else {
                throw FixtureError.appendFailed
            }
            written += frames
        }
    }

    /// 写一个 **10bit** 的 y4m（YUV4MPEG2）原始帧文件：给软解 10bit 那条路当输入（M04P21）。
    ///
    /// 为什么不用 AVAssetWriter 编 HEVC Main10：这台 SDK 的 AVAssetWriter 把
    /// `AVVideoProfileLevelKey` 判成非法 key，直接抛 NSException
    /// （`Output settings dictionary contains one or more invalid keys: ProfileLevel`）；
    /// 不给 profile 又只编 8bit。y4m 是 FFmpeg 原生的裸帧容器：10bit 数据原样进 rawvideo 解码器，
    /// 走的还是同一条「源格式 → sws → x420」—— 要测的东西一模一样，还不用求编码器。
    static func writeTenBitY4M(
        to url: URL,
        width: Int = 320,
        height: Int = 240,
        fps: Int = 30,
        frames: Int = 10
    ) throws {
        try? FileManager.default.removeItem(at: url)
        var data = Data()
        data.append(Data("YUV4MPEG2 W\(width) H\(height) F\(fps):1 Ip A1:1 C420p10\n".utf8))
        // 每帧 = `FRAME\n` + Y 平面（width×height 个 16bit 样本）+ U / V 平面（各一半边长）。
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        for frame in 0 ..< frames {
            data.append(Data("FRAME\n".utf8))
            appendSamples(&data, value: frame % 2 == 0 ? 64 : 800, count: width * height)
            appendSamples(&data, value: 512, count: chromaWidth * chromaHeight)
            appendSamples(&data, value: 512, count: chromaWidth * chromaHeight)
        }
        try data.write(to: url)
    }

    /// 往 y4m 里填一段**小端** 16bit 样本（y4m 的 10bit 就是「16bit 字里放 10bit 值」）。
    private static func appendSamples(_ data: inout Data, value: UInt16, count: Int) {
        let low = UInt8(value & 0xFF)
        let high = UInt8(value >> 8)
        var bytes = [UInt8](repeating: 0, count: count * 2)
        for index in 0 ..< count {
            bytes[index * 2] = low
            bytes[index * 2 + 1] = high
        }
        data.append(contentsOf: bytes)
    }

    /// 把整块 BGRA 填成一个灰度值（不用 CoreGraphics 画，省一层依赖）。
    private static func fill(_ pixelBuffer: CVPixelBuffer, gray: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        memset(base, Int32(gray), CVPixelBufferGetDataSize(pixelBuffer))
    }

    enum FixtureError: Error {
        case writerRejectedInput
        case startFailed
        case noPixelBufferPool
        case noPixelBuffer
        case appendFailed
        case finishFailed
        case noAudioBuffer
    }
}
