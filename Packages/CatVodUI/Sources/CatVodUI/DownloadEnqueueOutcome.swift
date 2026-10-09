/// 播放页「下载本集」交回上层的答案（M10h）。
///
/// 为什么要有这个类型，而不是继续返回 `Int`：以前是 `-1 / 0 / n` 三个约定值，
/// 调用点写成「`added == 0` ? 已在队列 : 已加入队列」—— `-1`（**压根没接线**）掉进了后半个分支，
/// 界面上写着「已加入下载队列」，其实什么都没发生。三种含义在这里各是一个 case，
/// 漏掉一种编译器就会拦下来。
///
/// **必须是 `public`**：它出现在 ``AppModel/enqueueDownloadsAndStart(_:siteKey:title:headers:)``
/// 的结果里、也在 `PlaybackView` 的公开 init 参数里 —— 那是两个 public 位置，
/// 类型低一级编译器就报「cannot be declared public because … uses an internal type」
/// （Mac 上 iOS 构建第一次就红在这）。
public enum DownloadEnqueueOutcome: Sendable, Equatable {
    /// 新加进队列 n 条（`n >= 1`；驱动已经开始跑）。
    case added(Int)
    /// 已经在队列里（同站点 + 同名 + 同集只下一次）。
    case alreadyQueued
    /// 这个入口不支持下载：没有站点上下文（直播、临时播放，或上层没接线）。
    case unsupported
}
