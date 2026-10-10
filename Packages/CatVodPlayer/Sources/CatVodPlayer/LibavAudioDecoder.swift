import CoreMedia
import Foundation

#if canImport(Libavcodec)
import Libavcodec
#endif
#if canImport(Libavformat)
import Libavformat
#endif
#if canImport(Libavutil)
import Libavutil
#endif
#if canImport(Libswresample)
import Libswresample
#endif

/// 自研 FFmpeg 内核（M4）的**音频解码层**（M04P10）：
/// 取包 → libavcodec 解码 → swresample 转 Float32 交错 → `CMSampleBuffer`。
///
/// 三个口径：
/// - **不挑硬解**：音频解码本来便宜，统一软解；
/// - **输出格式统一**：Float32 交错（见 ``LibavAudioSampleBuffer``），
///   采样率**不重采样**（输出 = 输入采样率）—— 换采样率是后面的事；
/// - **swresample 上下文 lazy 建**：要先拿到第一帧才知道源采样格式与声道布局。
///
/// 并发：`@unchecked Sendable` —— 句柄由持有者串行使用（将来是会话的解码线程）。
final class LibavAudioDecoder: @unchecked Sendable {
    private(set) var streamIndex = -1
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var resampler: OpaquePointer?
    private var outputChannels = 0
    private var outputSampleRate: Int32 = 0
    private var timeBase = AVRational(num: 0, den: 1)

    deinit {
        close()
    }

    /// 从已打开的输入里挑第一条音频流并建解码器。返回错误描述（nil = 成功）。
    func open(input: LibavInput) -> String? {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil) && canImport(Libswresample)
        close()
        guard let formatContext = input.rawFormatContext else {
            return "输入还没打开"
        }
        guard let index = input.firstStreamIndex(of: .audio),
              let stream = formatContext.pointee.streams?[index],
              let parameters = stream.pointee.codecpar
        else {
            return "没有音频流"
        }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            return "没有音频解码器：\(name)"
        }
        guard let codecContext = avcodec_alloc_context3(codec) else {
            return "音频解码器上下文创建失败"
        }
        self.codecContext = codecContext
        guard avcodec_parameters_to_context(codecContext, parameters) >= 0 else {
            close()
            return "音频解码参数拷贝失败"
        }
        guard avcodec_open2(codecContext, codec, nil) >= 0 else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            close()
            return "音频解码器初始化失败：\(name)"
        }
        guard let frame = av_frame_alloc() else {
            close()
            return "音频帧分配失败"
        }
        self.frame = frame
        streamIndex = index
        timeBase = stream.pointee.time_base
        return nil
        #else
        _ = input
        return "Libav 模块不可用（本构建未链接）"
        #endif
    }

    /// 喂一只**已按流过滤**的包；返回解出来的音频块（可能为空）。
    func feed(_ packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil) && canImport(Libswresample)
        guard codecContext != nil, packet.pointee.stream_index == Int32(streamIndex) else {
            return []
        }
        var samples: [CMSampleBuffer] = []
        var sendCode = avcodec_send_packet(codecContext, packet)
        // -EAGAIN = 解码器满了：先收块腾位置，再重发（与视频层同一用法）
        while sendCode == -EAGAIN {
            guard receive(into: &samples) else { break }
            sendCode = avcodec_send_packet(codecContext, packet)
        }
        guard sendCode >= 0 else { return samples }
        while receive(into: &samples) { }
        return samples
        #else
        _ = packet
        return []
        #endif
    }

    /// 收尾：把解码器里还缓着的音频块全收出来（EOF 之后调一次）。
    func drain() -> [CMSampleBuffer] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil) && canImport(Libswresample)
        guard let codecContext else { return [] }
        var samples: [CMSampleBuffer] = []
        _ = avcodec_send_packet(codecContext, nil) // NULL 包 = 冲解码器
        while receive(into: &samples) { }
        return samples
        #else
        return []
        #endif
    }

    /// 关闭（**幂等**）。
    func close() {
        #if canImport(Libavcodec) && canImport(Libavutil) && canImport(Libswresample)
        avcodec_free_context(&codecContext)
        av_frame_free(&frame)
        swr_free(&resampler)
        #endif
        codecContext = nil
        frame = nil
        resampler = nil
        streamIndex = -1
        outputChannels = 0
        outputSampleRate = 0
        timeBase = AVRational(num: 0, den: 1)
    }

    // MARK: - 内部

    /// 收一块。返回 false = 这次没得收（EAGAIN / EOF / 出错都算）。
    private func receive(into samples: inout [CMSampleBuffer]) -> Bool {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil) && canImport(Libswresample)
        guard let codecContext, let frame else { return false }
        guard avcodec_receive_frame(codecContext, frame) >= 0 else { return false }
        defer { av_frame_unref(frame) }
        if let sample = makeSample(from: frame) {
            samples.append(sample)
        }
        return true
        #else
        return false
        #endif
    }

    /// 一帧 → 一块 Float32 交错 PCM 的 CMSampleBuffer。
    private func makeSample(from frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        guard let resampler = ensureResampler(for: frame) else { return nil }
        let inputSamples = Int(frame.pointee.nb_samples)
        guard inputSamples > 0 else { return nil }
        let maxOutput = inputSamples + 4096 // 不重采样：输出 ≤ 输入，余量留给 swr 内部延迟
        let byteCount = maxOutput * outputChannels * MemoryLayout<Float>.size
        guard let raw = malloc(byteCount) else { return nil }
        var plane: UnsafeMutablePointer<UInt8>? = raw.assumingMemoryBound(to: UInt8.self)
        // 交错输入时只有 0 号平面有效；平面输入时每个声道一个 —— swr 都认，指针数组照传
        let inPlanes = UnsafeRawPointer(frame.pointee.extended_data)
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let produced = swr_convert(resampler, &plane, Int32(maxOutput), inPlanes, Int32(inputSamples))
        guard produced > 0 else {
            free(raw)
            return nil
        }
        let seconds = LibavVideoDecoder.seconds(
            pts: frame.pointee.pts,
            timeBaseNumerator: timeBase.num,
            timeBaseDenominator: timeBase.den
        )
        return LibavAudioSampleBuffer.make(
            ownedPCM: raw,
            frameCount: Int(produced),
            sampleRate: Double(outputSampleRate),
            channels: outputChannels,
            presentationSeconds: seconds
        )
    }

    /// swresample 上下文：第一帧来了才建（要拿源采样格式 / 声道布局）。
    ///
    /// 源格式中途变化不管：正常流不会变；真变了（拼接流）是「重建重采样器」的活，归后面。
    private func ensureResampler(for frame: UnsafeMutablePointer<AVFrame>) -> OpaquePointer? {
        if let resampler {
            return resampler
        }
        var inputLayout = frame.pointee.ch_layout
        guard inputLayout.nb_channels > 0 else { return nil }
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, inputLayout.nb_channels)
        var created: OpaquePointer?
        let code = swr_alloc_set_opts2(
            &created,
            &outputLayout,
            AV_SAMPLE_FMT_FLT,
            frame.pointee.sample_rate,
            &inputLayout,
            AVSampleFormat(rawValue: frame.pointee.format),
            frame.pointee.sample_rate,
            0,
            nil
        )
        guard code >= 0, let created else { return nil }
        guard swr_init(created) >= 0 else {
            var pointer: OpaquePointer? = created
            swr_free(&pointer)
            return nil
        }
        resampler = created
        outputChannels = Int(outputLayout.nb_channels)
        outputSampleRate = frame.pointee.sample_rate
        return created
    }
}
