import AVFoundation
@testable import CatVodPlayer
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 生成一个几帧的小 MP4（测试夹具）：给输入层 / demux 类测试一个**离线的确定性输入**。
///
/// 为什么不用真网络流：单测打网络 = 红绿看运气。这个夹具用 AVAssetWriter 现场编出来，
/// M04P7 的 demux 测试可以接着用。
enum TinyMP4Fixture {
    /// 写一个 `frames` 帧（`fps` 帧率）、黑/灰交替的 H.264 MP4；
    /// `audioSeconds > 0` 时再加一条等长的 AAC 音轨（M04P10 起；默认静音，
    /// `toneAmplitude > 0` 时写 440Hz 正弦 —— M04P23 增益测试要有声音可量）；
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
        secondAudioSampleRate: Double = 0,
        toneAmplitude: Double = 0
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
            try await appendAudio(to: audioInput, seconds: audioSeconds, amplitude: toneAmplitude)
            audioInput.markAsFinished()
        }
        if let secondAudioInput, audioSeconds > 0, secondAudioSampleRate > 0 {
            try await appendAudio(
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

    /// 正弦测试音的频率（440Hz，够量增益、也不至于给 AAC 编出怪东西）。
    private static let toneFrequency: Double = 440

    /// 往音轨写 PCM：默认静音；`amplitude > 0` 写正弦（M04P23 增益测试的音源）。
    /// LPCM 块复用 `LibavAudioSampleBuffer` 的封装 → writer input 自己编 AAC。
    private static func appendAudio(
        to input: AVAssetWriterInput,
        seconds: Double,
        sampleRate: Double = 44100,
        channels: Int = 2,
        amplitude: Double = 0
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
            if amplitude > 0 {
                let samples = raw.assumingMemoryBound(to: Float.self)
                for frame in 0 ..< frames {
                    let phase = 2 * Double.pi * toneFrequency * Double(written + frame) / sampleRate
                    let value = Float(amplitude * sin(phase))
                    for channel in 0 ..< channels {
                        samples[frame * channels + channel] = value
                    }
                }
            } else {
                memset(raw, 0, byteCount)
            }
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

    /// 读一块 Float32 交错音频样本的**峰值**（M04P23 增益测试用）：
    /// 增益是乘在样本上的，峰值之比就是增益之比（同一份源解两遍，解码器输出逐样本一致）。
    static func peak(of sample: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer else {
            return 0
        }
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for index in 0 ..< count {
            peak = max(peak, abs(floats[index]))
        }
        return peak
    }

    /// 写一个 **10bit（HEVC Main10）** 的小 MP4：给软解 10bit 那条路当输入（M04P21）。
    ///
    /// 为什么绕这么大一圈：这台 SDK 的 AVAssetWriter 把 `AVVideoProfileLevelKey` 判成非法 key、
    /// 直接抛 NSException；不给 profile 它又只编 8bit（x420 源也照压）。所以干脆不经过 AVFoundation
    /// 的编码器配置 —— 用 **VideoToolbox 直编**（`VTCompressionSession` + Main10 profile），
    /// 编出来的 `CMSampleBuffer` 交给 AVAssetWriter **直通**（`outputSettings: nil`）封成 mp4。
    static func writeTenBitHEVC(
        to url: URL,
        width: Int = 320,
        height: Int = 240,
        fps: Int = 30,
        frames: Int = 10
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        // 1) VideoToolbox 直编 Main10：先编完拿样本 —— 直通 input 要用样本的 format description 当 hint，
        //    没 hint 时 `writer.canAdd` 直接拒（首轮就撞在这）。
        let collector = HEVCSampleCollector()
        var session: VTCompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let refcon, let sampleBuffer else { return }
                Unmanaged<HEVCSampleCollector>.fromOpaque(refcon).takeUnretainedValue().append(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(collector).toOpaque(),
            compressionSessionOut: &session
        )
        guard created == noErr, let session else { throw FixtureError.videoToolbox(created) }
        defer { VTCompressionSessionInvalidate(session) }
        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel
        )
        guard profileStatus == noErr else { throw FixtureError.videoToolbox(profileStatus) }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTCompressionSessionPrepareToEncodeFrames(session)

        for frame in 0 ..< frames {
            let pixelBuffer = try makeTenBitBuffer(width: width, height: height, gray: frame % 2 == 0 ? 64 : 800)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)),
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            guard encodeStatus == noErr else { throw FixtureError.videoToolbox(encodeStatus) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        let samples = collector.sortedSamples()
        guard samples.count == frames, let firstSample = samples.first,
              let formatHint = CMSampleBufferGetFormatDescription(firstSample)
        else {
            throw FixtureError.encodedSampleMissing
        }

        // 2) AVAssetWriter 直通（`outputSettings: nil`）把编好的样本封成 mp4。
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureError.writerRejectedInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.startFailed }
        writer.startSession(atSourceTime: .zero)
        for sample in samples {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard input.append(sample) else { throw writer.error ?? FixtureError.appendFailed }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.finishFailed }
    }

    /// VT 的输出回调可能在别的线程上回来：样本先收进这里，编码完再按 pts 排好交给 writer。
    private final class HEVCSampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [(pts: CMTime, sample: CMSampleBuffer)] = []

        func append(_ sample: CMSampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            lock.lock()
            samples.append((pts, sample))
            lock.unlock()
        }

        func sortedSamples() -> [CMSampleBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return samples.sorted { $0.pts < $1.pts }.map { $0.sample }
        }
    }

    /// 造一张 x420（10bit 双平面）的灰度帧：Y 一个值、CbCr 中性 512（10bit 的中灰）。
    private static func makeTenBitBuffer(width: Int, height: Int, gray: UInt16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw FixtureError.noPixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        fillTenBitPlane(buffer, plane: 0, value: gray, columns: width, rows: height)
        fillTenBitPlane(buffer, plane: 1, value: 512, columns: (width + 1) / 2 * 2, rows: (height + 1) / 2)
        return buffer
    }

    private static func fillTenBitPlane(_ buffer: CVPixelBuffer, plane: Int, value: UInt16, columns: Int, rows: Int) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        for row in 0 ..< rows {
            let samples = (base + row * rowBytes).assumingMemoryBound(to: UInt16.self)
            for column in 0 ..< columns {
                samples[column] = value
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
        case videoToolbox(OSStatus)
        case encodedSampleMissing
    }
}
