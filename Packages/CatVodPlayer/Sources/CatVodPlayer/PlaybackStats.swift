import Foundation

/// 播放信息（M4 前置）：**先把「现在这一路到底是什么、跑得怎么样」量出来**。
///
/// 为什么先做这个：M4 的口径是「主做 HDR 与流畅度」，而这两件事都得先能看见 ——
/// 分辨率 / 编码 / 色彩（SDR 还是 HDR）/ 实际生效的硬解 / 丢帧数。
/// 屏幕上没有这些，"画质变好了没""流畅了没"就只能靠感觉吵。
///
/// 数据来源是内核报的属性（mpv 的属性名收在 ``MpvEngine`` 那一侧，见 ``PlaybackStatsProviding``），
/// 这里只管**把字符串拼成人话** —— 纯逻辑，不碰 C API，因此能单测。
public struct PlaybackStats: Sendable, Equatable {
    /// `video-params/w`。
    public var videoWidth: Int
    /// `video-params/h`。
    public var videoHeight: Int
    /// `video-format`：`hevc` / `h264` / `av1`…
    public var videoFormat: String
    /// `video-params/pixelformat`：`yuv420p` / `yuv420p10` / `p010`…
    public var pixelFormat: String
    /// `container-fps`（容器帧率）。
    public var fps: Double
    /// `video-params/primaries`：`bt.709` / `bt.2020`。
    public var primaries: String
    /// `video-params/gamma`：`bt.1886`（SDR）/ `pq` / `hlg`（HDR）。
    public var gamma: String
    /// `hwdec-current`：实际生效的硬解（`videotoolbox` / `no`）。
    ///
    /// 特意读 **current** 而不是设置项：设置里选了硬解、实际没启用，是最常见的一种"看起来在硬解"。
    public var hardwareDecoder: String
    /// `video-bitrate`（bit/s）；读不到给 0。
    public var videoBitrate: Int
    /// `frame-drop-count`（显示侧丢帧）。
    public var droppedFrames: Int
    /// `decoder-frame-drop-count`（解码侧丢帧）。
    public var decoderDroppedFrames: Int

    /// 从内核报的原始字符串建一份。**所有字段都可缺**（属性不存在、还没起播都给不了），
    /// 缺了就是 0 / 空串 —— 由界面按"空就不显示那一行"处理，不在这一层编默认值。
    public init(rawValues: [String: String] = [:]) {
        func text(_ key: String) -> String {
            (rawValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        videoWidth = Int(text("video-params/w")) ?? 0
        videoHeight = Int(text("video-params/h")) ?? 0
        videoFormat = text("video-format")
        pixelFormat = text("video-params/pixelformat")
        fps = Double(text("container-fps")) ?? 0
        primaries = text("video-params/primaries")
        gamma = text("video-params/gamma")
        hardwareDecoder = text("hwdec-current")
        videoBitrate = Int(text("video-bitrate")) ?? 0
        droppedFrames = Int(text("frame-drop-count")) ?? 0
        decoderDroppedFrames = Int(text("decoder-frame-drop-count")) ?? 0
    }

    /// 一条都没读到：界面据此**整块不显示**，而不是显示一排"未知"。
    public var isEmpty: Bool {
        videoWidth == 0 && videoHeight == 0
            && videoFormat.isEmpty && pixelFormat.isEmpty
            && fps == 0 && primaries.isEmpty && gamma.isEmpty
            && hardwareDecoder.isEmpty && videoBitrate == 0
            && droppedFrames == 0 && decoderDroppedFrames == 0
    }

    /// `3840×2160`；没读到给空串。
    public var resolutionText: String {
        videoWidth > 0 && videoHeight > 0 ? "\(videoWidth)×\(videoHeight)" : ""
    }

    /// `hevc · yuv420p10`。
    public var codecText: String {
        [videoFormat, pixelFormat]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// `24` / `23.976`：整数不留小数点，其余最多三位。
    public var fpsText: String {
        guard fps > 0 else {
            return ""
        }
        let rounded = (fps * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? "\(Int(rounded))" : "\(rounded)"
    }

    /// 这一路是不是 HDR：**只认 gamma**（mpv 里 HDR 是 `pq` / `hlg`）。
    ///
    /// 不拿 primaries 判：BT.2020 + BT.1886 的 10bit **SDR** 也存在，
    /// 按色域判会把 SDR 说成 HDR —— 那是比不显示更坏的一种错。
    public var isHDR: Bool {
        let value = gamma.lowercased()
        return value == "pq" || value == "hlg" || value == "smpte2084" || value == "smpte-st-2084"
    }

    /// `HDR · PQ (ST2084) · BT.2020` / `SDR · BT.709`；两样都没读到给空串。
    public var dynamicRangeText: String {
        guard !gamma.isEmpty || !primaries.isEmpty else {
            return ""
        }
        var parts = [isHDR ? "HDR" : "SDR"]
        if !gamma.isEmpty {
            parts.append(Self.colorLabel(gamma))
        }
        if !primaries.isEmpty {
            parts.append(Self.colorLabel(primaries))
        }
        return parts.joined(separator: " · ")
    }

    /// `硬件解码（VideoToolbox）` / `软件解码`；没读到（还没起播）给空串。
    public var decodeText: String {
        let value = hardwareDecoder.lowercased()
        if value.isEmpty {
            return ""
        }
        return value == "no" ? "软件解码" : "硬件解码（\(Self.colorLabel(hardwareDecoder))）"
    }

    /// `12.4 Mbps` / `800 kbps`；读不到（0）给空串 —— 本地文件常常报不出码率。
    public var bitrateText: String {
        guard videoBitrate > 0 else {
            return ""
        }
        let mbps = Double(videoBitrate) / 1_000_000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        }
        return String(format: "%.0f kbps", Double(videoBitrate) / 1000)
    }

    /// `无丢帧` / `显示 3 · 解码 1`。丢帧是"流畅度"唯一的硬证据，所以 0 也明说。
    public var dropText: String {
        if droppedFrames == 0, decoderDroppedFrames == 0 {
            return "无丢帧"
        }
        return "显示 \(droppedFrames) · 解码 \(decoderDroppedFrames)"
    }

    /// 色彩名词统一成人话（认不出来的原样输出，不猜）。
    private static func colorLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pq", "smpte2084", "smpte-st-2084": "PQ (ST2084)"
        case "hlg": "HLG"
        case "bt.709": "BT.709"
        case "bt.2020": "BT.2020"
        case "bt.1886": "BT.1886"
        case "bt.601": "BT.601"
        case "videotoolbox": "VideoToolbox"
        default: raw
        }
    }
}

/// 内核**可选**的「播放信息」能力（M4 前置）。
///
/// 不塞进 `PlayerEngine`：系统内核（`AVPlayer`）给不出这一套，也不该为它硬造；
/// 播放页按 `engine as? PlaybackStatsProviding` 决定显不显示那一块 ——
/// 与「轨道」同一套口径：**拿不到就不显示，不放空行**。
public protocol PlaybackStatsProviding: AnyObject, Sendable {
    /// 读一次当前播放信息（没在播 / 读不到就给空值，不抛错）。
    func playbackStats() async -> PlaybackStats
}
