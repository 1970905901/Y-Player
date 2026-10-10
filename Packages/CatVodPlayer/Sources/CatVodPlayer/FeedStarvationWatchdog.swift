import Foundation

/// **饥饿看门狗**（M04P17）：时钟是不是已经跑到数据前面了 —— 一个只有两个状态的小状态机。
///
/// 为什么需要它：`AVSampleBufferRenderSynchronizer` 的时钟是**按墙钟走**的 ——
/// 读包 / 解码跟不上时它不会等；等数据回来时，那批帧的 pts 全落在时钟后面，
/// 显示层按规矩把它们当「迟到帧」丢掉。表现就是：卡一下，然后画面突然快进一段。
///
/// 所以口径是「**时钟跟着帧走**」：由「时钟 - 最后一帧的 pts」来判饥饿，
/// 饿了就把表停住（同时报「缓冲中」让界面把弹幕 / 字幕的时钟也停下），有帧回来再接上。
///
/// 这里是**纯逻辑**（喂两个数、吐两个边沿），可以钉死在单测里；
/// 线程与渲染器的动作留给会话（`LibavFFmpegSession` 的看门狗线程）。
struct FeedStarvationWatchdog {
    /// 时钟超出最后一帧多少秒算「饿」。
    ///
    /// 0.3s：小于一帧的抖动（正常播放里时钟本来就会轻微领先）不该报缓冲，
    /// 而真正卡住时这个值也足够小 —— 用户看到的是「停一下」而不是「跳一段」。
    let threshold: Double

    /// 当前是不是处于饥饿（已上报）状态。
    private(set) var isStarving = false

    init(threshold: Double = 0.3) {
        self.threshold = threshold
    }

    /// 心跳：返回 true = **刚跨入**饥饿（只报一次，重复心跳不再报）。
    mutating func tick(clockSeconds: Double, lastFedSeconds: Double) -> Bool {
        let starvingNow = clockSeconds - lastFedSeconds > threshold
        guard starvingNow, !isStarving else {
            return false
        }
        isStarving = true
        return true
    }

    /// 刚喂了一帧：返回 true = **刚从**饥饿里出来（只报一次）。
    mutating func noteFeed() -> Bool {
        guard isStarving else {
            return false
        }
        isStarving = false
        return true
    }
}
