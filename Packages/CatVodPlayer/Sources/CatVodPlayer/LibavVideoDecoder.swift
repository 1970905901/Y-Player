import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if canImport(Libavcodec)
import Libavcodec
#endif
#if canImport(Libavformat)
import Libavformat
#endif
#if canImport(Libavutil)
import Libavutil
#endif
#if canImport(Libswscale)
import Libswscale
#endif

/// 自研 FFmpeg 内核（M4）的**视频解码层**（M04P7）：从已打开的输入里取包 → 喂解码器 → 吐 CVPixelBuffer。
///
/// 路径选择（M04P14 起两条都有，**严格按设置、不自动降级**）：
///
/// - `.hardware`：VT 直出 `CVPixelBuffer`（`AVFrame.data[3]`）。本机（或这个编码）硬解不可用时
///   **明确报错**，让用户去改设置；libav 中途掉回软解也**不算数**（记旗标，由会话停下并提示）；
/// - `.software`：帧经 libswscale 转成显示层吃的格式（8bit → 420v、10bit → x420；M04P18 / M04P21）。
///
/// 硬解那条：
/// - M4 的口径是「HDR 与流畅度」，硬解是这两件事的地基；
/// - VT 解出来的帧**本身就是 `CVPixelBuffer`**（在 `AVFrame.data[3]` 里），不需要 sws 转换。
///
/// 两条路的位深都不丢：硬解直出源帧；软解 10bit 也走 10bit 的 `x420`（M04P21）。
///
/// 并发：`@unchecked Sendable` —— 句柄由持有者串行使用（将来是会话的解码线程）。
final class LibavVideoDecoder: @unchecked Sendable {
    /// 一帧解码结果。
    struct Frame {
        /// 画面（位深随片源：10bit 片源两条路都是 10bit 的 buffer —— 硬解直出、软解转 x420）。
        var pixelBuffer: CVPixelBuffer
        /// 显示时间（秒，按流时基换算）。
        var seconds: Double
        /// 这一帧走的是哪条路：true = VT 硬解直出；false = 软解 + sws 转显示层格式（420v / x420）。
        ///
        /// 为什么要带上它：libav 会在硬解不可用时**自己掉回软解**，只有帧自己知道实情 ——
        /// 播放信息那行「解码」就靠它说实话。
        var isHardware: Bool
    }

    private var device: UnsafeMutablePointer<AVBufferRef>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    /// **借来的**（`LibavInput` 所有）：这里只读，不关。
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private(set) var streamIndex = -1
    private var timeBase = AVRational(num: 0, den: 1)

    /// 源的色彩信息（打开时读一次）：软解建 buffer 时按它挂 CoreVideo 色彩标签（M04P20）。
    private var sourcePrimaries: Int32 = 0
    private var sourceTransfer: Int32 = 0
    private var sourceMatrix: Int32 = 0

    /// 软解那条路的像素转换器（M04P14；M04P21 起 10bit 直通）：`yuv*` → **420v（8bit）/ x420（10bit）**。
    /// 按「源格式 + 尺寸」缓存，变了才重建（目标格式由源格式推出，不用另记）。
    ///
    /// 类型是 `UnsafeMutablePointer<SwsContext>`：libswscale 的头里 `struct SwsContext` 是**前向声明**，
    /// Swift 把它导成一个没有成员的 `SwsContext` —— 只在指针后面用（不是 `OpaquePointer`，别猜）。
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var swsSourceFormat: Int32 = -1
    private var swsWidth = 0
    private var swsHeight = 0

    /// 排障计数（M04P13 起）：「有声音没画面」得能取证 —— 解出几帧、丢了几帧、报了什么错。
    /// **只在解码线程里读写**（会话的日志也从那条线上打），所以不加锁。
    private(set) var decodedFrameCount = 0
    private(set) var hardwareFrameCount = 0
    private(set) var softwareFrameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var decodeErrorCount = 0
    private(set) var lastDecodeErrorText: String?

    /// 本次打开是不是「只认硬解」（`.hardware`）：收到软解帧就记旗标 —— **不自动降级**。
    private var requiresHardware = false
    private(set) var hardwareFallbackCount = 0

    /// 硬解模式下 libav 掉回软解过（会话据此停下并提示用户改设置）。
    var hardwareFallbackDetected: Bool {
        hardwareFallbackCount > 0
    }

    deinit {
        close()
    }

    /// 从已打开的输入里挑**第一条视频流**，按 `decoderMode` 建解码器。返回错误描述（nil = 成功）。
    ///
    /// 两条路（M04P14，**严格按设置、不自动降级**）：
    /// - `.hardware`：本机没硬解（`VTIsHardwareDecodeSupported`）或 VT 设备建不出来 → **返回错误**，
    ///   让用户去把设置改成软解；中途掉回软解也由会话停下报错（见 ``hardwareFallbackCount``）；
    /// - `.software`：不建设备，纯软解（帧由 sws 转成 420v）。
    ///
    /// 挑流用的也是「媒体类型字符串」而不是 C 枚举（同 `LibavInput`：少一类互操作坑）。
    func open(input: LibavInput, decoderMode: DecoderMode) -> String? {
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
        let codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            return "没有解码器：\(codecName)"
        }

        requiresHardware = decoderMode == .hardware
        // 硬解是**手动选择**：本机（或这个编码）没有硬解就当场说清楚，让用户去改设置 ——
        // 不自动降级（同 M02P3 对内核选择的纪律）。
        if requiresHardware {
            if let codecType = Self.videoToolboxCodecType(codecName: codecName),
               !VTIsHardwareDecodeSupported(codecType)
            {
                return "本机没有可用的 VideoToolbox 硬解（\(codecName)）——"
                    + "请到「设置 → 播放 → 解码方式」改成「软件解码」"
            }
            var device: UnsafeMutablePointer<AVBufferRef>?
            let deviceCode = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
            guard deviceCode >= 0, let created = device else {
                return "VideoToolbox 设备创建失败（\(LibavInput.errorText(deviceCode))）——"
                    + "请到「设置 → 播放 → 解码方式」改成「软件解码」"
            }
            self.device = created
        }

        guard let codecContext = avcodec_alloc_context3(codec) else {
            close()
            return "解码器上下文创建失败"
        }
        self.codecContext = codecContext
        guard avcodec_parameters_to_context(codecContext, parameters) >= 0 else {
            close()
            return "解码参数拷贝失败"
        }
        if let device {
            codecContext.pointee.hw_device_ctx = av_buffer_ref(device)
        }
        guard avcodec_open2(codecContext, codec, nil) >= 0 else {
            let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
            close()
            return "解码器初始化失败：\(name)"
        }

        self.formatContext = formatContext
        streamIndex = index
        timeBase = stream.pointee.time_base
        // 源的色彩信息：软解建 buffer 时要照着挂标签（硬解那条由 VT 自己挂）。
        sourcePrimaries = Int32(parameters.pointee.color_primaries.rawValue)
        sourceTransfer = Int32(parameters.pointee.color_trc.rawValue)
        sourceMatrix = Int32(parameters.pointee.color_space.rawValue)
        // 硬解有没有真的生效，看这一行：输出不是 VT 帧的话，后面每一帧都会被丢掉（= 有声音没画面）。
        let pixelFormat = codecContext.pointee.pix_fmt
        let hasDevice = device != nil
        // 这一行只说明「请求了什么」：硬解到底生不生效，看第一帧那次（`Frame.isHardware`）。
        let ready = "视频解码器就绪：流=\(index) 解码器=\(codecName) 模式=\(decoderMode.displayName) "
            + "设备=\(hasDevice) 输出格式=\(Int(pixelFormat.rawValue))"
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
        #if canImport(Libswscale)
        if let swsContext {
            sws_freeContext(swsContext)
        }
        #endif
        swsContext = nil
        swsSourceFormat = -1
        swsWidth = 0
        swsHeight = 0
        requiresHardware = false
        hardwareFallbackCount = 0
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
        let text = String(decoding: bytes, as: UTF8.self)
        let printable = text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return printable ? text : "0x\(String(type, radix: 16))"
    }

    /// 编码名 → CoreMedia 的编码类型（给 `VTIsHardwareDecodeSupported` 用来判「本机能不能硬解」）。
    ///
    /// 只列**能确证的**两种（H.264 / HEVC）—— 认不出来给 nil：那就不做前置检查，
    /// 交给第一帧的实测兜底（见 ``hardwareFallbackCount``）。宁可不判，也不猜错。
    static func videoToolboxCodecType(codecName: String) -> CMVideoCodecType? {
        switch codecName.lowercased() {
        case "h264": return kCMVideoCodecType_H264
        case "hevc": return kCMVideoCodecType_HEVC
        default: return nil
        }
    }

    /// 软解能转的像素格式 → libav 的枚举值；认不出来给 nil（如实丢帧 + 记账，不硬撑）。
    ///
    /// 用 `if` 而不是 `switch`：`AV_PIX_FMT_*` 是导入的枚举值，当不了 case 模式，
    /// 只能在 `Int32` 上比（同本文件里判 VT 帧的写法）。
    private static func softwareSourceFormat(_ raw: Int32) -> AVPixelFormat? {
        #if canImport(Libavutil)
        if raw == Int32(AV_PIX_FMT_YUV420P.rawValue) { return AV_PIX_FMT_YUV420P }
        if raw == Int32(AV_PIX_FMT_YUVJ420P.rawValue) { return AV_PIX_FMT_YUVJ420P }
        if raw == Int32(AV_PIX_FMT_YUV422P.rawValue) { return AV_PIX_FMT_YUV422P }
        if raw == Int32(AV_PIX_FMT_YUV444P.rawValue) { return AV_PIX_FMT_YUV444P }
        if raw == Int32(AV_PIX_FMT_NV12.rawValue) { return AV_PIX_FMT_NV12 }
        if raw == Int32(AV_PIX_FMT_YUV420P10LE.rawValue) { return AV_PIX_FMT_YUV420P10LE }
        if raw == Int32(AV_PIX_FMT_P010LE.rawValue) { return AV_PIX_FMT_P010LE }
        if raw == Int32(AV_PIX_FMT_BGRA.rawValue) { return AV_PIX_FMT_BGRA }
        return nil
        #else
        _ = raw
        return nil
        #endif
    }

    /// 软解帧 → 显示层吃的 `CVPixelBuffer`（M04P14 起；M04P18 从 BGRA 换成 420v；M04P21 起 10bit 走 x420）。
    ///
    /// 为什么不用 BGRA：
    /// - **省一档带宽**：BGRA 每像素 4 字节、还要先做一遍 YUV→RGB；420v 每像素 1.5 字节（x420 是 3 字节），
    ///   sws 只做尺寸 / 排布上的事，不做色彩换算 —— 软解那条路的每帧成本直接降一档；
    /// - **显示层原生吃它**：VT 硬解出来的帧本来就是 420v / x420 —— 软硬两条路交出去的东西长得一样。
    ///
    /// buffer 自己建而不是用 sws 的：显示层要 **IOSurface 背书**的 buffer，sws 分配的不是。
    /// 10bit 源（M04P21 起）直通 `P010` → `x420`，色彩标签照挂（PQ / HLG 能传到显示层）；
    /// 8bit 源照旧 `420v`。软解仍是兼容路线（不做 tone mapping，HDR 画质靠硬解那条）。
    private func makeSoftwarePixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        #if canImport(Libswscale) && canImport(Libavutil)
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0,
              let sourceFormat = Self.softwareSourceFormat(frame.pointee.format),
              let targetFormat = Self.softwareTargetFormat(sourceFormat),
              let pixelFormat = Self.coreVideoPixelFormat(forSoftwareTarget: targetFormat),
              let context = swsConverter(
                  width: width,
                  height: height,
                  sourceFormat: sourceFormat,
                  targetFormat: targetFormat
              )
        else {
            return nil
        }

        guard let target = av_frame_alloc() else { return nil }
        defer {
            var pointer: UnsafeMutablePointer<AVFrame>? = target
            av_frame_free(&pointer)
        }
        target.pointee.width = Int32(width)
        target.pointee.height = Int32(height)
        target.pointee.format = Int32(targetFormat.rawValue)
        guard av_frame_get_buffer(target, 0) >= 0, sws_scale_frame(context, target, frame) >= 0 else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        let code = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard code == kCVReturnSuccess, let pixelBuffer,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
        else {
            return nil
        }
        // 挂上**源的**色彩标签：420v / x420 什么都不带时 CoreVideo 会自己猜矩阵（对 1080p 这类片子常常猜错）；
        // 播放信息的「输出」那行读的就是这里挂上去的东西（硬解那条读 VT 挂的）。
        Self.attachColorTags(
            to: pixelBuffer,
            primaries: sourcePrimaries,
            transfer: sourceTransfer,
            matrix: sourceMatrix
        )
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        // 两个平面各拷各的：Y 是 height 行，CbCr 交织（420）是 ceil(height / 2) 行。
        let chromaRows = (height + 1) / 2
        guard copyPlane(0, rows: height, from: target.pointee.data.0, linesize: target.pointee.linesize.0, into: pixelBuffer),
              copyPlane(1, rows: chromaRows, from: target.pointee.data.1, linesize: target.pointee.linesize.1, into: pixelBuffer)
        else {
            return nil
        }
        return pixelBuffer
        #else
        _ = frame
        return nil
        #endif
    }

    /// 把一个平面的有效行拷进 `CVPixelBuffer` 的对应平面（行宽取两边小的那个）。
    ///
    /// 10bit（P010 ↔ x420）走的是同一条：两边都是「2 字节/样本、双平面」的同一套排布，字节级拷贝即可。
    private func copyPlane(
        _ plane: Int,
        rows: Int,
        from source: UnsafeMutablePointer<UInt8>?,
        linesize: Int32,
        into buffer: CVPixelBuffer
    ) -> Bool {
        guard let source, CVPixelBufferGetPlaneCount(buffer) > plane else { return false }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return false }
        let sourceRowBytes = Int(linesize)
        guard sourceRowBytes > 0 else { return false }
        let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let copyBytes = min(destinationRowBytes, sourceRowBytes)
        for row in 0 ..< rows {
            let destinationRow = base.advanced(by: row * destinationRowBytes)
            let sourceRow = UnsafeRawPointer(source).advanced(by: row * sourceRowBytes)
            destinationRow.copyMemory(from: sourceRow, byteCount: copyBytes)
        }
        return true
    }

    /// 缓存 sws 转换器（源格式 / 尺寸变了才重建）；建不出来给 nil。
    ///
    /// 目标格式由调用方按 ``softwareTargetFormat(_:)`` 推好传进来（10bit → P010，其余 NV12）——
    /// 缓存键因此还是「源格式 + 尺寸」，不用另记目标。
    private func swsConverter(
        width: Int,
        height: Int,
        sourceFormat: AVPixelFormat,
        targetFormat: AVPixelFormat
    ) -> UnsafeMutablePointer<SwsContext>? {
        #if canImport(Libswscale) && canImport(Libavutil)
        let format = Int32(sourceFormat.rawValue)
        if let swsContext, swsSourceFormat == format, swsWidth == width, swsHeight == height {
            return swsContext
        }
        if let swsContext {
            sws_freeContext(swsContext)
            self.swsContext = nil
        }
        // SWS_BILINEAR = 2：枚举常量导进来没有 int 重载，值写死（同 `LibavInput.avseekFlagBackward` 的写法）。
        let created = sws_getContext(
            Int32(width), Int32(height), sourceFormat,
            Int32(width), Int32(height), targetFormat,
            2, nil, nil, nil
        )
        swsContext = created
        swsSourceFormat = format
        swsWidth = width
        swsHeight = height
        return created
        #else
        _ = (width, height, sourceFormat, targetFormat)
        return nil
        #endif
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
                    // 计数拷进局部：OSLog 的插值是 escaping autoclosure，直接引用属性会被要求显式 self。
                    let count = decodeErrorCount
                    LibavTrace.logger.error(
                        "视频解码出错（第 \(count, privacy: .public) 次）：\(text, privacy: .public)"
                    )
                }
            }
            return false
        }
        let seconds = Self.seconds(
            pts: frame.pointee.pts,
            timeBaseNumerator: timeBase.num,
            timeBaseDenominator: timeBase.den
        )
        defer { av_frame_unref(frame) }
        // 硬解帧：VT 直出的 CVPixelBuffer 就在 data[3]（M04P7 定的路）。
        if frame.pointee.format == Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue) {
            guard let raw = frame.pointee.data.3 else { return true }
            // data[3] 就是 CVPixelBufferRef 本体；帧一还回解码器 buffer 就没了，所以这里要 retain。
            let pixelBuffer = Unmanaged<CVPixelBuffer>
                .fromOpaque(UnsafeRawPointer(raw))
                .retain()
                .takeRetainedValue()
            hardwareFrameCount += 1
            decodedFrameCount += 1
            if hardwareFrameCount == 1 {
                let format = Self.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
                let size = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
                let first = "第一帧硬解帧：pts=\(frame.pointee.pts) 像素格式=\(format) 尺寸=\(size)"
                LibavTrace.logger.notice("\(first, privacy: .public)")
            }
            frames.append(Frame(pixelBuffer: pixelBuffer, seconds: seconds, isHardware: true))
            return true
        }
        // 硬解模式却收到软解帧 = libav 自己掉回了软解：**不自动降级** —— 记旗标，
        // 由会话停下并提示用户去把设置改成「软件解码」。
        if requiresHardware {
            hardwareFallbackCount += 1
            if hardwareFallbackCount == 1 {
                let note = "硬解没生效：收到软解帧（format=\(Int(frame.pointee.format))）—— 按设置的「硬件解码」这不算数"
                LibavTrace.logger.error("\(note, privacy: .public)")
            }
            return true
        }
        // 软解帧（`.software`）：过 sws 转成显示层吃的格式（8bit 420v / 10bit x420）再送显示层 ——
        // 以前这里直接丢（只吃 VT 帧），界面上就是「有声音没画面」。
        guard let converted = makeSoftwarePixelBuffer(from: frame) else {
            droppedFrameCount += 1
            if droppedFrameCount <= 3 {
                let size = "\(Int(frame.pointee.width))x\(Int(frame.pointee.height))"
                let dropped = "软解帧转不出画面（format=\(Int(frame.pointee.format)) \(size)）"
                LibavTrace.logger.error("\(dropped, privacy: .public)")
            }
            return true
        }
        softwareFrameCount += 1
        decodedFrameCount += 1
        if softwareFrameCount == 1 {
            let output = Self.fourCC(CVPixelBufferGetPixelFormatType(converted))
            let size = "\(CVPixelBufferGetWidth(converted))x\(CVPixelBufferGetHeight(converted))"
            let first = "第一帧软解帧：format=\(Int(frame.pointee.format)) → \(output) \(size)"
            LibavTrace.logger.notice("\(first, privacy: .public)")
        }
        frames.append(Frame(pixelBuffer: converted, seconds: seconds, isHardware: false))
        return true
    }
}

// MARK: - 色彩标签（M04P20）

/// 色彩标签：软解建 buffer 时按**源**挂 CoreVideo 标签（硬解那条由 VideoToolbox 自己挂），
/// 送显示后从 buffer 上读回 —— 播放信息的「输出」行拿它说话。
///
/// 为什么拆成扩展：类型体行数（`type_body_length`）会把 CI 的 lint 顶红
/// （同 M04P16~P19 那几组的理由）；这些 `static` 成员不碰实例状态，拆出来零成本。
extension LibavVideoDecoder {
    /// 给自建的 buffer 挂上**源的**色彩标签（软解那条路；硬解由 VT 自己挂，M04P20）。
    ///
    /// 认不出的值**不挂**（宁可让 CoreVideo 按默认来，也不写一个假的）；
    /// 三个键分别是：色域 / 传输特性 / YCbCr 矩阵 —— 播放信息的「输出」行读回前两个来说话（矩阵只挂，没有出口）。
    static func attachColorTags(to buffer: CVPixelBuffer, primaries: Int32, transfer: Int32, matrix: Int32) {
        if let tag = colorPrimariesTag(primaries) {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, tag, .shouldPropagate)
        }
        if let tag = transferTag(transfer) {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tag, .shouldPropagate)
        }
        if let tag = matrixTag(matrix) {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, tag, .shouldPropagate)
        }
    }

    /// libav 的色域 → CoreVideo 的标签；认不出给 nil。
    static func colorPrimariesTag(_ raw: Int32) -> CFString? {
        #if canImport(Libavutil)
        if raw == Int32(AVCOL_PRI_BT709.rawValue) { return kCVImageBufferColorPrimaries_ITU_R_709_2 }
        if raw == Int32(AVCOL_PRI_BT2020.rawValue) { return kCVImageBufferColorPrimaries_ITU_R_2020 }
        if raw == Int32(AVCOL_PRI_SMPTE432.rawValue) { return kCVImageBufferColorPrimaries_P3_D65 }
        if raw == Int32(AVCOL_PRI_SMPTE170M.rawValue) { return kCVImageBufferColorPrimaries_SMPTE_C }
        if raw == Int32(AVCOL_PRI_BT470BG.rawValue) { return kCVImageBufferColorPrimaries_SMPTE_C }
        #endif
        return nil
    }

    /// libav 的传输特性 → CoreVideo 的标签（`SMPTE_ST_2084` / `HLG` 就是 HDR 那两种）；认不出给 nil。
    static func transferTag(_ raw: Int32) -> CFString? {
        #if canImport(Libavutil)
        if raw == Int32(AVCOL_TRC_SMPTE2084.rawValue) { return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ }
        if raw == Int32(AVCOL_TRC_ARIB_STD_B67.rawValue) { return kCVImageBufferTransferFunction_ITU_R_2100_HLG }
        if raw == Int32(AVCOL_TRC_BT709.rawValue) { return kCVImageBufferTransferFunction_ITU_R_709_2 }
        if raw == Int32(AVCOL_TRC_LINEAR.rawValue) { return kCVImageBufferTransferFunction_Linear }
        #endif
        return nil
    }

    /// libav 的矩阵 → CoreVideo 的标签；认不出给 nil。
    static func matrixTag(_ raw: Int32) -> CFString? {
        #if canImport(Libavutil)
        if raw == Int32(AVCOL_SPC_BT709.rawValue) { return kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
        if raw == Int32(AVCOL_SPC_BT2020_NCL.rawValue) { return kCVImageBufferYCbCrMatrix_ITU_R_2020 }
        if raw == Int32(AVCOL_SPC_SMPTE170M.rawValue) { return kCVImageBufferYCbCrMatrix_ITU_R_601_4 }
        if raw == Int32(AVCOL_SPC_BT470BG.rawValue) { return kCVImageBufferYCbCrMatrix_ITU_R_601_4 }
        #endif
        return nil
    }

    /// 从**送显示的那张 buffer 上读回**色彩标签（M04P20）：硬解那条是 VideoToolbox 自己挂的，
    /// 软解那条是 ``attachColorTags(to:primaries:transfer:matrix:)`` 挂的 —— 读回的是**实际挂上的**，
    /// 不是我们「打算挂的」。翻成播放信息那套名词；没挂或认不出都给 nil（那边「空就不显示」，不猜）。
    static func readColorTags(from buffer: CVPixelBuffer) -> (primaries: String?, gamma: String?) {
        let primariesTag = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let transferTag = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        return (
            primaries: primariesTag.flatMap { colorPrimariesName($0) },
            gamma: transferTag.flatMap { transferName($0) }
        )
    }

    /// CoreVideo 的色域标签 → 播放信息用的名字（``colorPrimariesTag(_:)`` 的反查）；认不出给 nil。
    static func colorPrimariesName(_ tag: String) -> String? {
        if tag == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) { return "bt.709" }
        if tag == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) { return "bt.2020" }
        if tag == (kCVImageBufferColorPrimaries_P3_D65 as String) { return "display-p3" }
        if tag == (kCVImageBufferColorPrimaries_SMPTE_C as String) { return "bt.601" }
        return nil
    }

    /// CoreVideo 的传输特性标签 → 播放信息用的名字（``transferTag(_:)`` 的反查；`pq` / `hlg` 即 HDR 两种）；
    /// 认不出给 nil。
    static func transferName(_ tag: String) -> String? {
        if tag == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return "pq" }
        if tag == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return "hlg" }
        if tag == (kCVImageBufferTransferFunction_ITU_R_709_2 as String) { return "bt.709" }
        if tag == (kCVImageBufferTransferFunction_Linear as String) { return "linear" }
        return nil
    }
}

// MARK: - 软解像素格式（M04P21）

/// 软解的像素格式映射：源格式 → 目标格式 → CoreVideo 格式。
///
/// 为什么拆成扩展：类型体行数（`type_body_length`）会把 lint 顶红（同 M04P16~P20 那几组的理由）；
/// 这几个 `static` 纯映射不碰实例状态，拆出来零成本。
extension LibavVideoDecoder {
    /// 软解的**目标**像素格式（M04P21）：10bit 源进 10bit 出 —— `yuv420p10le` / `p010le` → `P010LE`
    /// （macOS 侧就是 `x420`：10bit 双平面、高位对齐，sws 直出不用自己搬位）；其余照旧 NV12（420v）。
    static func softwareTargetFormat(_ source: AVPixelFormat) -> AVPixelFormat? {
        #if canImport(Libavutil)
        let code = Int32(source.rawValue)
        if code == Int32(AV_PIX_FMT_YUV420P10LE.rawValue) || code == Int32(AV_PIX_FMT_P010LE.rawValue) {
            return AV_PIX_FMT_P010LE
        }
        if softwareSourceFormat(code) != nil {
            return AV_PIX_FMT_NV12
        }
        #endif
        return nil
    }

    /// 软解目标（libav）→ CoreVideo 的像素格式（M04P21）：`P010LE` = **x420**、`NV12` = **420v**。
    static func coreVideoPixelFormat(forSoftwareTarget target: AVPixelFormat) -> OSType? {
        #if canImport(Libavutil)
        let code = Int32(target.rawValue)
        if code == Int32(AV_PIX_FMT_P010LE.rawValue) { return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
        if code == Int32(AV_PIX_FMT_NV12.rawValue) { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
        #endif
        return nil
    }
}
