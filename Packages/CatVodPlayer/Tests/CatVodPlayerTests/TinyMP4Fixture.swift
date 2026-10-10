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
    /// —— 换过去之后，喂来的样本采样率会变，那就是「真的换了」的证据）；
    /// `tenBitHEVC = true` 时视频改 **HEVC Main10**（x420 源进去），给软解 10bit 那条路当输入（M04P21）。
    ///
    /// 失败原因都带着走（writer.error 优先），别让调用方对着一个空文件猜。
    static func write(
        to url: URL,
        width: Int = 320,
        height: Int = 240,
        fps: Int = 30,
        frames: Int = 30,
        audioSeconds: Double = 0,
        secondAudioSampleRate: Double = 0,
        tenBitHEVC: Bool = false
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: tenBitHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: tenBitHEVC
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA,
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
            if tenBitHEVC {
                fillTenBit(pixelBuffer, gray: frame % 2 == 0 ? 64 : 800)
            } else {
                fill(pixelBuffer, gray: frame % 2 == 0 ? 32 : 200)
            }
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

    /// 把整块 x420（10bit 双平面）填成灰度：Y 一个值、CbCr 中性 512（10bit 的中灰）。
    private static func fillTenBit(_ pixelBuffer: CVPixelBuffer, gray: UInt16) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for row in 0 ..< height {
                let samples = (base + row * rowBytes).assumingMemoryBound(to: UInt16.self)
                for column in 0 ..< width {
                    samples[column] = gray
                }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let chromaColumns = (width + 1) / 2 * 2
            for row in 0 ..< ((height + 1) / 2) {
                let samples = (base + row * rowBytes).assumingMemoryBound(to: UInt16.self)
                for column in 0 ..< chromaColumns {
                    samples[column] = 512
                }
            }
        }
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
