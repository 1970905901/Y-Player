import CoreVideo
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

/// 自研 FFmpeg 内核（M4）的**视频解码层**（M04P7）：从已打开的输入里取包 → 喂解码器 → 吐 CVPixelBuffer。
///
/// 路径选择：**VideoToolbox 硬解优先** ——
/// - M4 的口径是「HDR 与流畅度」，硬解是这两件事的地基；
/// - VT 解出来的帧**本身就是 `CVPixelBuffer`**（在 `AVFrame.data[3]` 里），不需要 sws 转换，
///   也不会把 10bit / HDR 压成 8bit BGRA（软解 → BGRA 那条路会丢）。
///   软解回退是后话（等「软解」这个设置项真的有引擎去消费时再说）。
///
/// 并发：`@unchecked Sendable` —— 句柄由持有者串行使用（将来是会话的解码线程）。
final class LibavVideoDecoder: @unchecked Sendable {
    /// 一帧解码结果。
    struct Frame {
        /// VT 解出来的画面（位深随片源，HDR 的 10bit 也在这个 buffer 里）。
        var pixelBuffer: CVPixelBuffer
        /// 显示时间（秒，按流时基换算）。
        var seconds: Double
    }

    private var device: UnsafeMutablePointer<AVBufferRef>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    /// **借来的**（`LibavInput` 所有）：这里只读，不关。
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private(set) var streamIndex = -1
    private var timeBase = AVRational(num: 0, den: 1)

    /// 排障计数（M04P13 起）：「有声音没画面」得能取证 —— 解出几帧、丢了几帧、报了什么错。
    /// **只在解码线程里读写**（会话的日志也从那条线上打），所以不加锁。
    private(set) var decodedFrameCount = 0
    private(set) var droppedNonVTCount = 0
    private(set) var decodeErrorCount = 0
    private(set) var lastDecodeErrorText: String?

    deinit {
        close()
    }

    /// 从已打开的输入里挑**第一条视频流**，为它建 VideoToolbox 解码器。返回错误描述（nil = 成功）。
    ///
    /// 挑流用的也是「媒体类型字符串」而不是 C 枚举（同 `LibavInput`：少一类互操作坑）。
    func open(input: LibavInput) -> String? {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        close()
        guard let formatContext = input.rawFormatContext else {
            return "输入还没打开"
        }
        guard let index = input.firstStreamIndex(of: .video),
              let stream = formatContext.pointee.streams?[index],
              let parameters = stream.pointee.codecpar
        else {
            return "没有视频流"
        }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            return "没有解码器：\(name)"
        }

        // VideoToolbox 设备（硬解的地基）。建不出来就明确报错，而不是悄悄退回软解。
        var device: UnsafeMutablePointer<AVBufferRef>?
        let deviceCode = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
        guard deviceCode >= 0, let device else {
            return "VideoToolbox 设备创建失败：\(LibavInput.errorText(deviceCode))"
        }
        self.device = device

        guard let codecContext = avcodec_alloc_context3(codec) else {
            close()
            return "解码器上下文创建失败"
        }
        self.codecContext = codecContext
        guard avcodec_parameters_to_context(codecContext, parameters) >= 0 else {
            close()
            return "解码参数拷贝失败"
        }
        codecContext.pointee.hw_device_ctx = av_buffer_ref(device)
        guard avcodec_open2(codecContext, codec, nil) >= 0 else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            close()
            return "解码器初始化失败：\(name)"
        }

        self.formatContext = formatContext
        streamIndex = index
        timeBase = stream.pointee.time_base
        // 硬解有没有真的生效，看这一行：输出不是 VT 帧的话，后面每一帧都会被丢掉（= 有声音没画面）。
        let codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        let vtActive = codecContext.pointee.pix_fmt == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue)
        let ready = "视频解码器就绪：流=\(index) 解码器=\(codecName) "
            + "输出格式=\(Int(codecContext.pointee.pix_fmt)) VT=\(vtActive)"
        LibavTrace.logger.notice("\(ready, privacy: .public)")
        return nil
        #else
        _ = input
        return "Libav 模块不可用（本构建未链接）"
        #endif
    }

    /// 解出接下来的**至多** `count` 帧（到 EOF / 出错就少给，不抛错）。
    func decodeFrames(_ count: Int) -> [Frame] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        guard let formatContext, codecContext != nil, streamIndex >= 0, count > 0 else {
            return []
        }
        var frames: [Frame] = []
        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else {
            return []
        }
        defer {
            var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
            var framePointer: UnsafeMutablePointer<AVFrame>? = frame
            av_packet_free(&packetPointer)
            av_frame_free(&framePointer)
        }

        while frames.count < count {
            let readCode = av_read_frame(formatContext, packet)
            guard readCode >= 0 else { break }
            if packet.pointee.stream_index == Int32(streamIndex) {
                push(packet, frame: frame, into: &frames, limit: count)
            }
            av_packet_unref(packet)
        }
        return frames
        #else
        _ = count
        return []
        #endif
    }

    /// 喂一只**已按流过滤**的包（会话统一 demux 的路：见 ``LibavInput/nextPacket()``）。
    ///
    /// 与 `decodeFrames` 的区别：包从外面来 —— 多流复用时只能有一个读包的人，
    /// 那个人是会话。
    func feed(_ packet: UnsafeMutablePointer<AVPacket>) -> [Frame] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        guard codecContext != nil, packet.pointee.stream_index == Int32(streamIndex) else {
            return []
        }
        var frames: [Frame] = []
        guard let frame = av_frame_alloc() else { return [] }
        defer {
            var framePointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&framePointer)
        }
        push(packet, frame: frame, into: &frames, limit: Int.max)
        return frames
        #else
        _ = packet
        return []
        #endif
    }

    /// 跳转后清解码器内部状态（B 帧 / 硬解缓冲）——
    /// 不清的话，跳完头几帧会把旧位置附近缓存的帧吐出来。
    func flush() {
        #if canImport(Libavcodec)
        if let codecContext {
            avcodec_flush_buffers(codecContext)
        }
        #endif
    }

    /// 收尾：把解码器里还缓着的帧全收出来（EOF 之后调一次）。
    ///
    /// 硬解与 B 帧都会在解码器里留几帧，不冲一下就少画面。
    func drain() -> [Frame] {
        #if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
        guard let codecContext else { return [] }
        var frames: [Frame] = []
        guard let frame = av_frame_alloc() else { return [] }
        defer {
            var framePointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&framePointer)
        }
        _ = avcodec_send_packet(codecContext, nil) // NULL 包 = 冲解码器
        while receive(into: &frames, frame: frame, limit: Int.max) { }
        return frames
        #else
        return []
        #endif
    }

    /// 关闭（**幂等**）。不碰借来的 `formatContext`。
    func close() {
        #if canImport(Libavcodec) && canImport(Libavutil)
        avcodec_free_context(&codecContext)
        av_buffer_unref(&device)
        #endif
        codecContext = nil
        device = nil
        formatContext = nil
        streamIndex = -1
        timeBase = AVRational(num: 0, den: 1)
    }

    /// pts（流时基）→ 秒；无效 pts（`AV_NOPTS_VALUE` = Int64 最小值）给 0。
    ///
    /// 自己算而不引 `av_q2d`：一个除法的事，少一个宏/内联函数的互操作面。
    /// 签名也**不摆 `AVRational`**：纯算术的测试不该被迫 `import Libavutil`
    /// （测试目标不继承包的 import —— M04P7 第一版就是这么红的）。
    static func seconds(pts: Int64, timeBaseNumerator: Int32, timeBaseDenominator: Int32) -> Double {
        guard pts != Int64.min, timeBaseDenominator != 0 else { return 0 }
        return Double(pts) * Double(timeBaseNumerator) / Double(timeBaseDenominator)
    }

    /// 像素格式的 fourCC 写法（日志用）：`420v` / `x420` / `BGRA` 这种。
    ///
    /// CoreVideo 的类型本身就是 fourCC（`OSType`）：高位在前拼成 4 个字符。
    /// 看它是因为**有些显示层 / 设备组合渲染不了 10bit（`x420`）** —— 黑屏时先看这一格。
    static func fourCC(_ type: OSType) -> String {
        let bytes = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF),
            UInt8(type & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        let printable = text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return printable ? text : "0x\(String(type, radix: 16))"
    }

    // MARK: - 内部

    /// 把一只包喂给解码器，并尽力把解码器里已备好的帧收进 `frames`（上限 `limit`）。
    private func push(
        _ packet: UnsafeMutablePointer<AVPacket>,
        frame: UnsafeMutablePointer<AVFrame>,
        into frames: inout [Frame],
        limit: Int
    ) {
        guard let codecContext else { return }
        var sendCode = avcodec_send_packet(codecContext, packet)
        // -EAGAIN = 解码器满了：先收帧腾位置，再重发（libav 的标准用法）
        while sendCode == -EAGAIN, frames.count < limit {
            guard receive(into: &frames, frame: frame, limit: limit) else { break }
            sendCode = avcodec_send_packet(codecContext, packet)
        }
        guard sendCode >= 0 else { return }
        while frames.count < limit, receive(into: &frames, frame: frame, limit: limit) { }
    }

    /// 收一帧。返回 false = 这次没得收（EAGAIN / EOF / 出错都算 —— 对调用方语义相同）。
    private func receive(
        into frames: inout [Frame],
        frame: UnsafeMutablePointer<AVFrame>,
        limit: Int
    ) -> Bool {
        guard let codecContext, frames.count < limit else { return false }
        let code = avcodec_receive_frame(codecContext, frame)
        guard code >= 0 else {
            // EAGAIN / EOF 是常规返回；别的都是解码器在报错 —— 记下来（以前这里全吞了）。
            if code != LibavInput.againCode, code != LibavInput.eofCode {
                decodeErrorCount += 1
                let text = LibavInput.errorText(code)
                lastDecodeErrorText = text
                if decodeErrorCount <= 3 {
                    LibavTrace.logger.error(
                        "视频解码出错（第 \(decodeErrorCount, privacy: .public) 次）：\(text, privacy: .public)"
                    )
                }
            }
            return false
        }
        defer { av_frame_unref(frame) }
        // 这版只吃 VideoToolbox 的硬解帧：不是就丢掉（不悄悄降级成软解）—— 但**要说出来**，
        // 否则「硬解没生效」在界面上只表现为黑屏。
        guard frame.pointee.format == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue) else {
            droppedNonVTCount += 1
            if droppedNonVTCount <= 3 {
                LibavTrace.logger.error(
                    "丢帧：硬解没生效，收到非 VT 帧（format=\(Int(frame.pointee.format), privacy: .public)）"
                )
            }
            return true
        }
        guard let raw = frame.pointee.data.3 else { return true }
        // data[3] 就是 CVPixelBufferRef 本体；帧一还回解码器 buffer 就没了，所以这里要 retain。
        let pixelBuffer = Unmanaged<CVPixelBuffer>
            .fromOpaque(UnsafeRawPointer(raw))
            .retain()
            .takeRetainedValue()
        decodedFrameCount += 1
        if decodedFrameCount == 1 {
            let format = Self.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
            let size = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
            let first = "第一帧硬解帧：pts=\(frame.pointee.pts) 像素格式=\(format) 尺寸=\(size)"
            LibavTrace.logger.notice("\(first, privacy: .public)")
        }
        frames.append(Frame(
            pixelBuffer: pixelBuffer,
            seconds: Self.seconds(
                pts: frame.pointee.pts,
                timeBaseNumerator: timeBase.num,
                timeBaseDenominator: timeBase.den
            )
        ))
        return true
    }
}
