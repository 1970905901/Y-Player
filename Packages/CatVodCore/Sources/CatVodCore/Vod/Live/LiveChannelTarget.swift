import Foundation

/// 换台的目标：**分组 + 频道**。
///
/// 组内换台只换频道（``LiveChannelNavigation/neighbor(of:step:in:)`` 直接返回 `LiveChannel`）；
/// 跨分组换台与按号码跳台都可能换到**另一个分组**，所以要把分组一起带回来
/// （上游 `LiveConfig.findByChannelNumber(number, items)` 返回的就是 `{分组下标, 频道下标}`）。
public struct LiveChannelTarget: Sendable, Hashable {
    /// 目标分组。
    public let group: LiveGroup
    /// 目标频道（一定可播：没有地址的频道不会被选成目标）。
    public let channel: LiveChannel

    public init(group: LiveGroup, channel: LiveChannel) {
        self.group = group
        self.channel = channel
    }
}
