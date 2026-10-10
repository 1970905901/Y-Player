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

/// 自研 FFmpeg 内核（M4）的**输入层**：打开媒体、读出流信息（M04P6）。
///
/// 范围就一件事：**打开 → 读 → 关**。demux / 解码 / 渲染从 M04P7 起 ——
/// 但「自定义 headers 能不能真的进到 FFmpeg」「流信息读出来长什么样」这两件事
/// 不需要等画面就能验，而且它们错了后面全错。
///
/// 这是全工程**第一个碰 libav 的文件**（M04P5 的分层承诺：C 调用不越界）。
/// 后面的真会话只对着 `LibavInput` 编程，不再直接写 `av*` 调用。
///
/// 并发：`@unchecked Sendable` —— 可变状态只有 `context` 一个句柄，
/// 由持有者串行使用（将来的会话从自己的队列里调）。
final class LibavInput: @unchecked Sendable {
    /// 打开后读到的**一条流**。
    struct StreamInfo: Equatable, Sendable {
        /// 流的类别（由 FFmpeg 的媒体类型字符串翻过来，避免 Swift 里比对 C 枚举）。
        enum Kind: Equatable, Sendable {
            case video
            case audio
            case subtitle
            case other

            init(typeText: String) {
                switch typeText {
                case "video": self = .video
                case "audio": self = .audio
                case "subtitle": self = .subtitle
                default: self = .other
                }
            }
        }

        var index: Int
        var kind: Kind
        /// FFmpeg 的编码名（`avcodec_get_name`，如 `h264` / `hevc` / `aac`）。
        var codecName: String
        /// 视频才有（其余为 0）。
        var width: Int
        var height: Int
    }

    /// 一只**借来的**包（见 ``nextPacket()`` 的生命周期约定）。
    struct Packet {
        /// 包属于哪条流（会话拿它分发）。
        var streamIndex: Int
        /// 包本体（借的，不用也不许 free）。
        let pointer: UnsafeMutablePointer<AVPacket>
    }

    /// 一次读取的媒体信息（纯值，给引擎 / 诊断用）。
    struct MediaInfo: Equatable, Sendable {
        /// 容器报的时长（秒）；读不到为 0。
        var durationSeconds: Double
        /// 容器名（`mov,mp4,m4a,3gp,3g2,mj2` 这类，FFmpeg 的说法）；读不到给空串。
        var containerName: String
        var streams: [StreamInfo]
    }

    private var context: UnsafeMutablePointer<AVFormatContext>?
    /// 复用的读包缓冲（`nextPacket()` 用；close 时释放）。
    private var packetBuffer: UnsafeMutablePointer<AVPacket>?
    /// 上一次 `nextPacket()` 是否读到文件尾。
    private(set) var isAtEnd = false

    deinit {
        close()
    }

    // MARK: - 打开 / 读 / 关

    /// 打开媒体。返回错误描述（nil = 成功）。
    ///
    /// `headers` 走 FFmpeg 的 http 协议选项（映射规则见 ``httpOptions(from:)``）——
    /// 这就是「带自定义头去拉流」在自研内核里的落点。
    func open(url: String, headers: [String: String]) -> String? {
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
        close()
        isAtEnd = false
        var options: OpaquePointer?
        for (name, value) in Self.httpOptions(from: headers) {
            av_dict_set(&options, name, value, 0)
        }
        defer { av_dict_free(&options) }

        var handle: UnsafeMutablePointer<AVFormatContext>?
        let openCode = avformat_open_input(&handle, url, nil, &options)
        guard openCode >= 0, let context = handle else {
            // 按文档失败时 *ps 已被置空；这一步是双保险（close 对 NULL 是空操作）。
            avformat_close_input(&handle)
            return "打开失败：\(Self.errorText(openCode))"
        }
        // 先接管句柄：后面无论哪步失败，都用 `close()` 这一个出口释放。
        self.context = context
        let infoCode = avformat_find_stream_info(context, nil)
        guard infoCode >= 0 else {
            close()
            return "读取流信息失败：\(Self.errorText(infoCode))"
        }
        return nil
        #else
        _ = url
        _ = headers
        return "Libav 模块不可用（本构建未链接）"
        #endif
    }

    /// 读一次媒体信息；没打开给 nil。
    func mediaInfo() -> MediaInfo? {
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
        guard let context else { return nil }
        var streams: [StreamInfo] = []
        if let list = context.pointee.streams {
            for index in 0 ..< Int(context.pointee.nb_streams) {
                guard let stream = list[index], let parameters = stream.pointee.codecpar else {
                    continue
                }
                let typeText: String
                if let typePointer = av_get_media_type_string(parameters.pointee.codec_type) {
                    typeText = String(cString: typePointer)
                } else {
                    typeText = ""
                }
                streams.append(StreamInfo(
                    index: index,
                    kind: StreamInfo.Kind(typeText: typeText),
                    codecName: String(cString: avcodec_get_name(parameters.pointee.codec_id)),
                    width: Int(parameters.pointee.width),
                    height: Int(parameters.pointee.height)
                ))
            }
        }
        let rawDuration = context.pointee.duration
        let containerName = context.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        return MediaInfo(
            durationSeconds: rawDuration > 0 ? Double(rawDuration) / Self.avTimeBase : 0,
            containerName: containerName,
            streams: streams
        )
        #else
        return nil
        #endif
    }

    /// 读下一只包。
    ///
    /// 指针是**借来的**：到下一次 `nextPacket()` / `close()` 前有效 ——
    /// 解码器要即取即喂，不许扣着留。EOF / 出错给 nil（``isAtEnd`` 标出 EOF）。
    /// 这是统一 demux 的入口：会话按 `streamIndex` 分发给视频 / 音频解码器。
    func nextPacket() -> Packet? {
        #if canImport(Libavformat) && canImport(Libavcodec)
        guard let context else { return nil }
        if packetBuffer == nil {
            packetBuffer = av_packet_alloc()
        }
        guard let packet = packetBuffer else { return nil }
        av_packet_unref(packet)
        let code = av_read_frame(context, packet)
        guard code >= 0 else {
            isAtEnd = code == Self.eofCode
            return nil
        }
        return Packet(streamIndex: Int(packet.pointee.stream_index), pointer: packet)
        #else
        return nil
        #endif
    }

    /// 找第一条指定类别的流（按媒体类型字符串判，不比 C 枚举 —— 与 `mediaInfo()` 同一口径）。
    func firstStreamIndex(of kind: StreamInfo.Kind) -> Int? {
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
        guard let context, let list = context.pointee.streams else { return nil }
        for candidate in 0 ..< Int(context.pointee.nb_streams) {
            guard let stream = list[candidate], let parameters = stream.pointee.codecpar else {
                continue
            }
            guard let typePointer = av_get_media_type_string(parameters.pointee.codec_type) else {
                continue
            }
            if StreamInfo.Kind(typeText: String(cString: typePointer)) == kind {
                return candidate
            }
        }
        return nil
        #else
        _ = kind
        return nil
        #endif
    }

    /// 底层格式上下文的**借用口**（只给同模块的解码层：`LibavVideoDecoder.open(input:)`）。
    ///
    /// 句柄仍归本类所有（open / close 管生命周期）—— 借的人**不许**自己关它。
    var rawFormatContext: UnsafeMutablePointer<AVFormatContext>? {
        context
    }

    /// 关闭。**幂等**：没打开 / 关两次都安全。
    func close() {
        #if canImport(Libavformat) && canImport(Libavcodec)
        avformat_close_input(&context)
        av_packet_free(&packetBuffer)
        #endif
        context = nil
        isAtEnd = false
    }

    // MARK: - 纯映射（可单测）

    /// `MediaResource.headers` → FFmpeg 的 http 选项。
    ///
    /// - `User-Agent` / `Referer` 有**专名选项**（塞进 `headers` 串会产生重复请求头）；
    /// - 其余拼成一段 `名: 值`（`\r\n` 分隔）交给 `headers`；
    ///   按名排序只为输出稳定（便于排查与断言），与请求语义无关。
    static func httpOptions(from headers: [String: String]) -> [String: String] {
        var options: [String: String] = [:]
        var extra: [String] = []
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            switch name.lowercased() {
            case "user-agent":
                options["user_agent"] = value
            case "referer":
                options["referer"] = value
            default:
                extra.append("\(name): \(value)")
            }
        }
        if !extra.isEmpty {
            options["headers"] = extra.joined(separator: "\r\n")
        }
        return options
    }

    /// FFmpeg 的媒体时长时间基（`AV_TIME_BASE`：1 秒 = 1000000）。
    ///
    /// 写成字面量：`AV_TIME_BASE` 是宏，Swift 能不能导入它取决于构建配置；
    /// 而「微秒」本身是 FFmpeg 的固定约定（`duration` 字段的文档单位）。
    private static let avTimeBase: Double = 1_000_000

    /// `AVERROR_EOF`（宏导不进来，值写死）：`FFERRTAG('E','O','F',' ')`。
    /// 读包层与解码层共用这一处定义。
    static let eofCode: Int32 = -541_478_725

    #if canImport(Libavformat) && canImport(Libavutil)
    /// `av_strerror` 的人话版（FFmpeg 惯例缓冲区 256 字节）。
    ///
    /// 同模块的解码层也用（`LibavInput.errorText(...)`）—— 错误文案只有这一处权威。
    static func errorText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if av_strerror(code, &buffer, buffer.count) == 0 {
            return String(cString: buffer)
        }
        return "错误码 \(code)"
    }
    #endif
}
