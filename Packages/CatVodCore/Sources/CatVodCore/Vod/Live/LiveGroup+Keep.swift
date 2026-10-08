import Foundation

/// 「收藏」分组的约定。
///
/// 上游：`LiveApi.parse` 在清单前面插一个 `Group.create(R.string.keep)`（**永远在第 0 组**），
/// `Group.isKeep()` 用名字判断是不是它，`LiveConfig.applyKeepsToGroups` 再把收藏的频道塞进去。
/// 于是上游「上次观看」的默认落点写成 `{1, 0}`（第 0 组是收藏组，所以从第 1 组起）。
extension LiveGroup {
    /// 「收藏」分组名。上游取资源字符串，本项目固定这一个中文名，界面与 `selectedLiveGroup` 的落盘值共用。
    public static var keepName: String {
        "收藏"
    }

    /// 是不是「收藏」分组（上游 `Group.isKeep()`）。
    public var isKeep: Bool {
        name == LiveGroup.keepName
    }
}
