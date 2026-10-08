import Foundation

/// 直播「上次观看」（上游 `bean/Live.java` 的 `keep` 字段 + `Live.keep(Channel)`）。
///
/// 上游写入的就是一行三段拼接：
/// `channel.getGroup().getName() + AppDatabase.SYMBOL + channel.getName() + AppDatabase.SYMBOL + channel.getCurrent()`
/// —— `AppDatabase.SYMBOL` 是字面量 `@@@`（M07c-2 交接时已核实），`getCurrent()` 是**线路下标**。
///
/// 这个类型只管两件事：一行字符串 ↔ 三个字段的编解码，以及「这段记录落在清单里的哪条频道」。
/// 谁写、什么时候写是界面的事（见 `CatVodUI/AppModel+Live.swift` 的 `rememberLiveChannel`），
/// 与上游另一个同名的 `Keep` 表（**收藏频道**）不是一回事，不要混。
public struct LiveKeep: Sendable, Hashable {
    /// 分组名（**原文**，不脱 `_密码` 后缀：上游写进去的就是 `Group.getName()`）。
    public let group: String
    /// 频道名（原文）。
    public let channel: String
    /// 线路下标（频道 `urls` 的下标，从 0 开始）。
    public let line: Int

    /// 字段分隔符（上游 `AppDatabase.SYMBOL`）。
    public static let separator = "@@@"

    /// 构造；负的线路下标按 0 处理。
    public init(group: String, channel: String, line: Int = 0) {
        self.group = group
        self.channel = channel
        self.line = max(line, 0)
    }

    /// 从上游那一行字符串解析；解析不出来返回 `nil`（调用方按「没有上次观看」处理）。
    ///
    /// 宽容之处都是「源或存档坏了也不该炸」：
    /// - 多于三段：忽略多出来的段（上游将来加字段时旧解析仍能用）；
    /// - 第三段缺失 / 不是数字 / 是负数：按下标 0（上游 `Channel.getCurrent()` 默认也是 0）；
    /// - 少于两段、或分组名 / 频道名为空：`nil`。
    public init?(raw: String) {
        let parts = raw.components(separatedBy: Self.separator)
        guard parts.count >= 2 else {
            return nil
        }
        let groupName = parts[0]
        let channelName = parts[1]
        guard !groupName.isEmpty, !channelName.isEmpty else {
            return nil
        }
        self.init(group: groupName, channel: channelName, line: parts.count >= 3 ? Int(parts[2]) ?? 0 : 0)
    }

    /// 编码回上游那一行（写回源 / 落存档时用）。
    public var rawValue: String {
        [group, channel, String(line)].joined(separator: Self.separator)
    }

    /// 落到某个已解析的清单上：**分组名 + 频道名 → 频道名 → 线路下标** 三级回落。
    ///
    /// - 分组名命不中时在全部频道里按名字找（源改过分组名也能回到那个频道）；
    /// - 线路下标越界回落第 0 条（源换了线路数量）；
    /// - 频道找不到返回 `nil`（清单换过，旧记录作废）。
    public func resolve(in source: LiveSource) -> LiveKeepTarget? {
        let wantedGroup = group
        let wantedChannel = channel
        if let matchedGroup = source.groups.first(where: { $0.name == wantedGroup }),
           let matchedChannel = matchedGroup.channels.first(where: { $0.name == wantedChannel })
        {
            return LiveKeepTarget(group: matchedGroup, channel: matchedChannel, lineIndex: resolvedLine(for: matchedChannel))
        }
        for matchedGroup in source.groups {
            if let matchedChannel = matchedGroup.channels.first(where: { $0.name == wantedChannel }) {
                return LiveKeepTarget(group: matchedGroup, channel: matchedChannel, lineIndex: resolvedLine(for: matchedChannel))
            }
        }
        return nil
    }

    /// 线路下标越界时回落第 0 条（上游 `getCurrent()` 也只在地址列表非空时有意义）。
    private func resolvedLine(for channel: LiveChannel) -> Int {
        channel.urls.indices.contains(line) ? line : 0
    }
}
