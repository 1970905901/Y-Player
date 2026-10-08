import CatVodCore
import Foundation

// 换台的「第二步」：跨分组换台与按号码跳台（M07d-6）。
//
// 上游把这两件事分开：`LiveActivity` 的 `across` 动作（跨组）与 `LiveConfig.findByChannelNumber`
// （按号跳）。本项目此前只做了组内环形换台（M07d-3），一个分组几十上百个频道时够用，
// 但「跳到下一个分组」「直接输 008」这两件事没有入口。
//
// 三个函数各自的边界条件都写在文档注释里，并由 `LiveChannelNavigationTests` 钉住：
// - `neighbor(of:step:in:)`（M07d-3）：组内环形、跳过没有地址的频道；
// - `across(in:groups:step:)`：跨组走到邻组的**边界频道**（往后取第一个可播、往前取最后一个），
//   跳过整组不可播的分组，一圈都找不到时回到当前分组（循环，不在边界失效）；
// - `channel(number:in:)`：按号扫描（两边能解析成整数就按整数比，前导零/空白不影响），
//   空串 / 非数字 / 找不到一律 nil（上游 `Integer.parseInt` 会抛异常，界面不该跟着崩）。


import Foundation

/// 播放页换台的取值语义。
///
/// 上游是 `LiveActivity` 的 `control.next` / `control.prev` → `mLive.nextChannel()` / `mLive.prevChannel()`
/// （`mLive.nextChannel()` 的定义在本地没取到的那个类里，`player/Live*`），另外竖向滑动
/// （`onFlingUp` / `onFlingDown`）也走同一对方法，`LiveSetting.isInvert()` 只用来反转滑动方向。
///
/// 本项目按直播换台的通行做法定三条，都已写进测试：
/// - **只在当前分组内换**（跨组换台在上游是另一个动作，本项目未做）；
/// - **环形**：到最后一条再按「下一台」回到第一条（换台是循环的，不该在边界上失效）；
/// - **跳过没有地址的频道**（切过去也播不了，等于把用户卡住）。
public enum LiveChannelNavigation {
    /// 相对当前位置偏移 `step` 的频道（正数往后、负数往前）。
    ///
    /// - 当前频道**不在** `channels` 里（清单换过、名字对不上）：返回第一个可播的 —— 比什么都不做有用；
    /// - `step == 0`、或可播的频道不足两个：返回 `nil`（没有可换的，界面据此把按钮置灰）；
    /// - 只有一条可播时同样返回 `nil`：切过去还是它。
    public static func neighbor(of channel: LiveChannel, step: Int, in channels: [LiveChannel]) -> LiveChannel? {
        guard step != 0 else {
            return nil
        }
        let playable = channels.filter { !$0.urls.isEmpty }
        guard playable.count > 1 else {
            return nil
        }
        guard let index = playable.firstIndex(where: { $0.name == channel.name }) else {
            return playable[0]
        }
        // Swift 的 `%` 保留负号，所以先加一圈再取模。
        let count = playable.count
        let target = ((index + step) % count + count) % count
        return playable[target]
    }

    /// **跨分组**换台（上游 `LiveActivity` 的 `across` 动作）：走到相邻分组的**边界频道**。
    ///
    /// - 往后（`step > 0`）去下一个分组的**第一个**可播频道；往前（`step < 0`）去上一个分组的**最后一个**
    ///   （换台习惯：跨组是「跳到那一组的门口」，不是随机挑一个）；
    /// - **跳过没有可播频道的分组**；一圈都找不到就回到当前分组的边界频道（循环换台，不在边界失效）；
    /// - 只有一个分组、或 `step == 0`：返回 `nil`（界面据此把按钮置灰）；
    /// - `group` 不在 `groups` 里（清单换过）：返回 `nil`。
    public static func across(
        in group: LiveGroup,
        groups: [LiveGroup],
        step: Int
    ) -> LiveChannelTarget? {
        guard step != 0, groups.count > 1 else {
            return nil
        }
        guard let start = groups.firstIndex(where: { $0.name == group.name }) else {
            return nil
        }
        let count = groups.count
        for offset in 1 ... count {
            let index = (((start + step * offset) % count) + count) % count
            let candidate = groups[index]
            // 往后取第一个可播、往前取最后一个可播；整个组都没可播的频道就跳过这一组。
            let boundary = step > 0
                ? candidate.channels.first { !$0.urls.isEmpty }
                : candidate.channels.last { !$0.urls.isEmpty }
            if let playable = boundary {
                return LiveChannelTarget(group: candidate, channel: playable)
            }
        }
        return nil
    }

    /// 按**频道号**跳台（上游 `LiveConfig.findByChannelNumber(number, items)`）。
    ///
    /// - 号比较：两边都能解析成整数就按整数比（清单里常见 `001` / `1` 混写），否则退化成去空白后的字符串相等；
    /// - 分组顺序、组内顺序扫描，取**第一个**命中的（上游用 `find` 逐个分组找，语义一致）；
    /// - 找不到、空串、或压根不是数字：返回 `nil`（上游 `Integer.parseInt` 会在非数字上抛异常 ——
    ///   那是它的问题，界面不该崩）。
    public static func channel(number: String, in groups: [LiveGroup]) -> LiveChannelTarget? {
        let wanted = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return nil
        }
        let wantedValue = Int(wanted)
        for group in groups {
            for channel in group.channels where matches(number: channel.number, wanted, wantedValue) {
                return LiveChannelTarget(group: group, channel: channel)
            }
        }
        return nil
    }

    /// 频道号是否命中：能按整数比就按整数比，否则字符串相等。
    private static func matches(number: String, _ wanted: String, _ wantedValue: Int?) -> Bool {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if let wantedValue, let value = Int(trimmed) {
            return value == wantedValue
        }
        return trimmed == wanted
    }
}
