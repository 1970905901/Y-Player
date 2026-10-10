import CoreGraphics
import Foundation

/// 播放页「一甩切集」的判定（M03P23，对齐上游 mobile 的 `onFlingUp` / `onFlingDown`）。
///
/// 为什么单独立一条纯规则：SwiftUI 的 `DragGesture` 不给速度（只有位移与预测终点），而纵向拖
/// 已经被音量 / 亮度占着 —— 「是不是一甩」得自己采样算出来，也就必须能单独测出来。
/// 采样（``PlaybackSwipeTracker``）与判定（``PlaybackSwipeRules``）都在这儿，视图只管按结果做事。
///
/// `public` 的理由同 ``PlaybackPlaylist`` / ``PlaybackLineSwitcher``：`PlaybackView` 是 public，
/// 它的 init 收 `((PlaybackSwipeAction) -> Void)?` —— 参数类型不能比 init 更内敛。
public enum PlaybackSwipeAction: Equatable {
    /// 上滑（点播页 = 下一集；直播页 = 上一台 —— 两个页面方向相反，所以这里只报「上 / 下」，含义由页面定）。
    case up
    /// 下滑（点播页 = 上一集；直播页 = 下一台）。
    case down
}

/// 拖动过程中的采样器：只留最近 ``PlaybackSwipeTracker/window`` 秒的 `(时刻, 纵向位移)`。
///
/// 为什么用窗口而不是「起点到终点」：慢慢拖到最后停住再松手，位移很大但**没有速度** ——
/// 那是调音量，不是切集（上游靠 `GestureDetector.onFling` 的速度门槛分开这两件事）。
struct PlaybackSwipeTracker {
    /// 只看最近这段时间的样本：更早的甩不算数。
    static let window: TimeInterval = 0.15

    private var samples: [(time: TimeInterval, y: Double)] = []

    /// 记一次拖动上报；`time` 用调用方给的时钟（测试里给假时间）。
    mutating func record(at time: TimeInterval, y: Double) {
        samples.append((time: time, y: y))
        let cutoff = time - Self.window
        while let first = samples.first, first.time < cutoff {
            samples.removeFirst()
        }
    }

    /// 松手那一刻的速度（pt/s，取大小）。
    ///
    /// 最后一个样本比 `now` 旧出一个窗口（手指停在原地不动了）就算 0 ——
    /// 慢慢拖到底再松手不该被当成甩。
    func speed(at now: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else {
            return 0
        }
        guard now - last.time <= Self.window else {
            return 0
        }
        return abs((last.y - first.y) / (last.time - first.time))
    }

    mutating func reset() {
        samples.removeAll()
    }
}

/// 一甩的判据（**纯函数**，有单测）：四条一起过才算 —— 起手在中间一半、纵向位移够长、
/// 几乎笔直上下、松手时还在跑。
enum PlaybackSwipeRules {
    /// 位移下限（pt）。上游 `DISTANCE = 100`（px，换算过来三十几 dp）；取 60 是
    /// 「一甩够长、慢拖不误触」的折中。
    static let minimumDistance: CGFloat = 60
    /// 速度下限（pt/s）：慢拖每秒一两百 pt，够不着。
    static let minimumSpeed: Double = 700
    /// 纵向的斜率下限（上游 `angle > 70` 的 `tan 70°` ≈ 2.747）：越陡越像甩。
    static let verticalSlope: CGFloat = 2.747

    /// 起手在不在「中间一半」（`w/4 … 3w/4`）。
    ///
    /// 上游 `isSide` 的反面：**侧边四分之一里的纵甩是音量 / 亮度，不切集**。
    /// 我们音量 / 亮度的分区是左右半屏（M03P12 定的，比上游宽），但切集区照抄上游 ——
    /// 不然「快速调音量」会被切集吃掉。
    static func isCenterZone(startX: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else {
            return true
        }
        return startX >= width / 4 && startX <= width * 3 / 4
    }

    /// 这次松手算不算一甩；算的话是切哪边（上滑 = 下一集）。
    static func action(
        translation: CGSize,
        speed: Double,
        startX: CGFloat,
        width: CGFloat
    ) -> PlaybackSwipeAction? {
        guard isCenterZone(startX: startX, width: width) else {
            return nil
        }
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard dy >= minimumDistance, dy > dx * verticalSlope else {
            return nil
        }
        guard speed >= minimumSpeed else {
            return nil
        }
        return translation.height < 0 ? .up : .down
    }
}
