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
}
