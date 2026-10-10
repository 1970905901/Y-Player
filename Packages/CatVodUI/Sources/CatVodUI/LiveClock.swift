import Foundation
import SwiftUI

/// 直播页的「现在」（M07d8）。
///
/// 节目单的「正在播 / 未开始 / 可回看」全是**按时间算的**，可 `body` 只在该视图的**被观察状态**
/// 变化时才重算 —— 预取队列跑完后就没有状态再变了，行上的时间会一直冻在那一刻：
/// 19:30 过后，「正在播」还写着 19:00 那档，列表就成了假话。
///
/// 这个时钟把「现在」按**整分钟**喂回来（节目按分钟切；对齐整分钟而不是每 30 秒空刷）。
enum LiveClock {
    /// 距离下一个整分钟还有多少秒；正好落在整分钟上时给满 60 秒（别给 0，那会变成空转的定时器）。
    static func secondsUntilNextMinute(from date: Date) -> TimeInterval {
        let remainder = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        return 60 - remainder
    }
}

/// 按整分钟把「现在」写回绑定的修饰器：`@State private var now = Date()` + `.liveClock($now)`。
///
/// 用 `.task` 实现：视图消失（切走 Tab / 关掉弹层）时随视图一起取消，不留孤儿定时器。
struct LiveClockModifier: ViewModifier {
    @Binding var now: Date

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                // 多睡 50ms：落在整分钟**之后**再看表，避免刚好卡在边界上读到上一分钟。
                let delay = LiveClock.secondsUntilNextMinute(from: Date()) + 0.05
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                now = Date()
            }
        }
    }
}

extension View {
    /// 见 ``LiveClockModifier``。
    func liveClock(_ now: Binding<Date>) -> some View {
        modifier(LiveClockModifier(now: now))
    }
}
