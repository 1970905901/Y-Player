import os

/// 自研内核的**排障日志**（M04P13 起）：把我们自己的事实（帧数 / 显示层状态 / 错误码）打进系统日志。
///
/// 为什么需要它：`.ffmpeg` 这条链路的失败常常是**静默**的 —— VT 建不出会话、硬解没生效、
/// 显示层进了 failed，屏幕上只表现为「黑着但有声音」。这些事实以前只活在内存里，没人看得见。
/// 现在一条命令就能取全部（子系统就是 App 的 bundle id）：
///
///     xcrun simctl spawn booted log show --last 5m --predicate 'subsystem == "com.YPlayer.cat"'
///
/// 只记**我们自己的事实**，不转发 libav 内部的 `av_log`（那要碰 C 的可变参数，不值当）。
/// 插值一律标 `.public`：os_log 默认把值打码成 `<private>`，不标就等于白打。
enum LibavTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "ffmpeg")
}
