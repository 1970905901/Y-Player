import Foundation

/// 播放页的「画面比例 / 缩放」（M03P9，对齐参考实现 `select_scale` + `player.setResizeMode`）。
///
/// **档位是本项目定的**：参考实现的具体档位表在它的 Android 资源里，我们没拿到 ——
/// 所以只给语义自明的几档（名字本身就是意思，不猜），并且每一档都写清**哪个内核做得到**：
///
/// | 档位 | MPV | 自研 FFmpeg | 系统内核 |
/// | --- | --- | --- | --- |
/// | 适应 / 裁剪铺满 / 拉伸铺满 | ✅ | ✅（`videoGravity` 三态） | ❌ |
/// | 16:9 / 4:3 | ✅（`video-aspect-override`） | ❌ | ❌ |
///
/// 界面只列**当前内核真的支持**的档位（``supportedModes(by:)``）—— 系统内核整行不出现，
/// 不摆点了没反应的开关（「解码方式对系统内核无效」那条是标注，这个干脆不显示）。
public enum PlaybackScaleMode: String, Sendable, CaseIterable, Hashable {
    /// 适应（默认）：保持比例，留黑边。
    case fit
    /// 强制按 16:9 显示。
    case ratio16x9
    /// 强制按 4:3 显示。
    case ratio4x3
    /// 裁剪铺满：保持比例放大到铺满，超出部分裁掉。
    case crop
    /// 拉伸铺满：不保持比例，直接铺满（画面会变形）。
    case stretch

    public var displayName: String {
        switch self {
        case .fit: "适应"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .crop: "裁剪铺满"
        case .stretch: "拉伸铺满"
        }
    }

    /// 从进度记录里的存档串还原（M03P19）：空串 / 认不出的值回落 ``fit`` ——
    /// 坏存档不该让画面变形（与「坏倍速回正常速度」同一口径）。
    public static func decode(_ raw: String?) -> PlaybackScaleMode {
        guard let raw, let mode = PlaybackScaleMode(rawValue: raw) else {
            return .fit
        }
        return mode
    }

    /// 某个内核实不实做得到这一档。
    public func isSupported(by engine: PlayerEngineKind) -> Bool {
        switch engine {
        case .system:
            false
        case .mpv:
            true
        case .ffmpeg:
            // 自研内核只有 `AVSampleBufferDisplayLayer.videoGravity` 三态：「强制某个比例」
            // gravity 表达不了（要自己算层的 frame，不在这一轮的范围里）。
            self == .fit || self == .crop || self == .stretch
        }
    }

    /// 某内核支持的档位（保持声明顺序）；**空数组 = 这个内核没有这个能力**。
    public static func supportedModes(by engine: PlayerEngineKind) -> [PlaybackScaleMode] {
        allCases.filter { $0.isSupported(by: engine) }
    }
}
