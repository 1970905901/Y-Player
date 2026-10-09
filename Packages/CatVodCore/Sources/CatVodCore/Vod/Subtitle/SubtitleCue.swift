import Foundation

/// 一条字幕：起止时间（秒）+ 文本。
///
/// 为什么要自己解析：上游跑在 ExoPlayer 上，SRT / ASS 都由它内置解析；
/// **iOS 侧没有这条通道** —— `AVPlayer` 只认 HLS 内嵌字幕，外挂字幕（``SubtitleSource``
/// 给出的那种 `.srt` / `.vtt` 地址）要自己下、自己解、自己画。
///
/// 这个类型只描述**一条**字幕，语言之类的属性属于 ``SubtitleSource``，不放在这里：
/// 同一个字幕文件里的每条 cue 都是同一语言，塞进来只会到处传同样的值。
public struct SubtitleCue: Sendable, Hashable {
    /// 起始时间（秒）。
    public var start: Double
    /// 结束时间（秒）。
    public var end: Double
    /// 文本；多行用 `\n` 连接（原文件里就是一个 cue 的几行）。
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// 该时刻是否应该显示这条字幕（**含**结束那一刻，与弹幕调度同一套边界口径）。
    public func isVisible(at time: Double) -> Bool {
        time >= start && time <= end
    }
}
