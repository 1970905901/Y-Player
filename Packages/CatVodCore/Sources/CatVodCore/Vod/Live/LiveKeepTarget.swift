import Foundation

/// 「上次观看」在某份已解析清单上的落点（``LiveKeep/resolve(in:)`` 的结果）。
///
/// 界面拿它是为了三件事：把分组条切到 ``group``、用 ``channel`` + ``lineIndex`` 直接开播、
/// 在列表里给这一行标「上次」。模型本身不就地改：清单是解析结果，观看记录是另一份数据。
public struct LiveKeepTarget: Sendable, Hashable {
    /// 命中的分组。
    public let group: LiveGroup
    /// 命中的频道。
    public let channel: LiveChannel
    /// 线路下标（已被 ``LiveKeep`` 按这个频道的实际线路数收敛）。
    public let lineIndex: Int

    public init(group: LiveGroup, channel: LiveChannel, lineIndex: Int) {
        self.group = group
        self.channel = channel
        self.lineIndex = lineIndex
    }

    /// 这条线路上有没有地址（没有就点不动，界面不该给「继续观看」入口）。
    public var isPlayable: Bool {
        channel.urls.indices.contains(lineIndex)
    }
}
