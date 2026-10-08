import Foundation

/// 「只想拿到某个频道现在在哪一组」的入口。
///
/// 两个真实场景：
/// - **收藏分组**里的频道是清单的副本，界面不知道它原来在哪个组（写「上次观看」要写**真组**）；
/// - 频道可能在清单里被移到了别的组（源更新过），按名字回查比记着旧分组更稳。
public extension LiveKeep {
    /// 只按**频道名**定位：在全部组里找这个名字，返回命中的分组 + 频道（线路下标按传入值收敛）。
    ///
    /// 频道不在清单里返回 `nil`。加密（隐藏）分组的判断交给调用方 —— 例如
    /// 「加密分组里的频道不记上次观看、也不给收藏」（上游 `LiveConfig.setKeep` /
    /// `LiveActivity.onLongClick` 都是先看 `group.isHidden()`）。
    static func locate(channelNamed name: String, in source: LiveSource, line: Int = 0) -> LiveKeepTarget? {
        LiveKeep(group: "", channel: name, line: line).resolve(in: source)
    }
}
