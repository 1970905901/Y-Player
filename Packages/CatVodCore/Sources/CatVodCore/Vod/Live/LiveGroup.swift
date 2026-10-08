import Foundation

/// 直播分组。
///
/// 逐条对齐上游 `bean/Group.java`：
/// - 分组名形如 `分组名_密码`：含 `_` 时**按第一个 `_` 拆两段**（`split("_", 2)`），
///   后半段是访问密码；``isHidden`` 即「密码非空」（上游 `isHidden`）；
/// - 直播源的 `pass` 为 true 时**不做这个拆分**（上游 `Group.create(name, live.isPass())`）——
///   有些源的组名里本来就有 `_`，不能被当成密码；
/// - ``indexOfChannel(named:)`` 对应上游 `find(Channel)`：同名返回已有下标，否则追加一个新的；
/// - ``merge(_:)`` 对应上游 `add(Channel)`：同名**只合并 URLs**（已配好的频道级 header/时移等设置保留）。
public struct LiveGroup: Codable, Sendable, Hashable, Identifiable {
    /// 分组名（`分组名_密码` 的前半段）。
    public var name: String
    /// 访问密码；非空表示这是隐藏分组。
    public var pass: String
    /// 频道列表（顺序即展示顺序）。
    public var channels: [LiveChannel]

    /// 同一分组名 + 密码视为同一分组（对应上游 `Group.equals` 的「名字 + 频道数」近似语义，这里用名字 + 密码更稳）。
    public var id: String {
        pass.isEmpty ? name : name + "_" + pass
    }

    public init(name: String = "", pass: String = "", channels: [LiveChannel] = []) {
        let splits = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        self.name = String(splits.first ?? "")
        if pass.isEmpty, splits.count == 2 {
            self.pass = String(splits[1])
        } else {
            self.pass = pass
        }
        self.channels = channels
    }

    /// 上游 `Group(name, pass)` 的第二个参数是一个「**不要**把 `_` 当密码分隔符」的开关
    /// （来自 `Live.isPass()`）—— 有些源的组名里本来就有 `_`。
    public init(name: String, skipPasswordSplit: Bool) {
        if skipPasswordSplit {
            self.name = name
            pass = ""
        } else {
            let splits = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            self.name = String(splits.first ?? "")
            pass = splits.count == 2 ? String(splits[1]) : ""
        }
        channels = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = container.lenientString(.name)
        let splits = rawName.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        name = String(splits.first ?? "")
        let decodedPass = container.lenientString(.pass)
        pass = decodedPass.isEmpty && splits.count == 2 ? String(splits[1]) : decodedPass
        channels = container.lenientArray(.channel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        container.encode(pass.isEmpty ? name : name + "_" + pass, forKey: .name)
        container.encode(pass, forKey: .pass)
        container.encode(channels, forKey: .channel)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case pass
        case channel
    }

    /// 上游 `isHidden()`：密码非空就是隐藏分组（界面上默认不展开）。
    public var isHidden: Bool {
        !pass.isEmpty
    }

    /// 上游 `find(Channel)`：同名返回已有下标（`--`），没有就追加一个新的并返回它的下标。
    public mutating func indexOfChannel(named channelName: String) -> Int {
        if let index = channels.firstIndex(where: { $0.name == channelName }) {
            return index
        }
        channels.append(LiveChannel(name: channelName))
        return channels.count - 1
    }

    /// 上游 `add(Channel)`：同名合并 URLs，否则整体追加。
    public mutating func merge(_ channel: LiveChannel) {
        guard let index = channels.firstIndex(where: { $0.name == channel.name }) else {
            channels.append(channel)
            return
        }
        channels[index].urls.append(contentsOf: channel.urls)
    }
}
