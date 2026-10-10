import CatVodPlayer
import Foundation
import SwiftUI

/// 播放页的手势（自绘内核：MPV / 自研 FFmpeg）。
///
/// 手势**只挂在自绘内核**：系统内核的画面是 `VideoPlayer`，它自带一整套手势，再叠一层只会互相打架
/// （M02P15 的「长按临时加速」当时就是因此没做，到这一批才给自绘内核补上）。
///
/// | 手势 | 行为 |
/// | --- | --- |
/// | 双击 | 播放 / 暂停 |
/// | 单击 | 显隐控制条（双击优先，M03P10） |
/// | 长按 | 临时加速，松手回到用户那份倍速（M03P12）；不在播不加速，但手势照样接管 |
/// | 横拖 | 调进度：拖动中只预览，**松手才 seek**（一次拖动几十个中间值，逐个 seek 会把内核打爆） |
/// | 左半屏纵拖 | 调屏幕亮度：拖动中即时生效；拿不到亮度（macOS）则这次拖动不做事 |
/// | 右半屏纵拖 | 调音量：拖动中只看百分比，**松手下发内核** |
///
/// 这次拖动调什么由**起点**决定（``DragMode``），开始那一刻定下就不再变 ——
/// 横向拖到一半拐弯也不会突然跳成调音量。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数顶到了 SwiftLint 的 `file_length` error（800）——
/// 拆文件不如拆职责：主文件留播放本体，手势独立成文件（与 `PlaybackView+Overlays` / `+Stats` 同一套做法）。
/// 跨文件的成员不能带 `private`：主文件里被这里用到的 `@State` 与两个方法因此改成了默认（internal）。
extension PlaybackView {
    /// 这次拖动在调什么。
    enum DragMode: Equatable {
        case seek
        /// 左半屏纵向：屏幕亮度。
        case brightness
        /// 右半屏纵向：App 内音量。
        case volume
    }

    /// 换算常量：横向拖满一屏宽 ≈ 120 秒（M03P6）；纵向 200pt 走满量程（音量与亮度共用）。
    static let seekSecondsPerScreen: Double = 120
    static let verticalPointsForFullRange: Double = 200

    /// 长按多久算「长按」：0.5 秒（与系统一致）。
    static let speedBoostHoldSeconds: Double = 0.5
    /// 按住期间允许的抖动（超过这个距离就不算长按，交给拖动那条）。
    static let speedBoostMaxDistance: CGFloat = 10
    /// 松手后多久内补发的点按要吞掉（同一次触摸的尾巴）。
    static let speedBoostSwallowSeconds: TimeInterval = 0.5

    // MARK: - 判定与换算（纯函数，有单测）

    /// 这次拖动调什么：横向主导 → 进度；纵向主导 → 按起点分左右半屏（左亮度 / 右音量，中线算右半屏）。
    static func dragMode(dx: CGFloat, dy: CGFloat, startX: CGFloat, width: CGFloat) -> DragMode {
        guard abs(dx) <= abs(dy) else {
            return .seek
        }
        return startX < width / 2 ? .brightness : .volume
    }

    /// 横向拖了多少 → 目标秒数（夹在 0...总时长）。
    static func seekTarget(base: Double, dx: CGFloat, width: CGFloat, duration: Double) -> Double {
        let delta = Double(dx / max(width, 1)) * seekSecondsPerScreen
        return min(max(base + delta, 0), max(duration, 0))
    }

    /// 纵向拖了多少 → 目标值：向上加、向下减，`pointsForFullRange` pt 走满量程，结果夹在 0...1。
    static func verticalValue(base: Double, dy: CGFloat, pointsForFullRange: Double) -> Double {
        min(max(base - Double(dy) / pointsForFullRange, 0), 1)
    }

    /// 长按加速能不能开始（纯函数，有单测）：上游同款守卫 —— 不在播就按了也白按。
    static func canStartSpeedBoost(isPlaying: Bool, isBoosting: Bool) -> Bool {
        isPlaying && !isBoosting
    }

    // MARK: - 画面外壳

    /// 自绘内核画面的共同外壳：单击 / 双击 / 长按 / 拖动全在这一层。
    ///
    /// **单击 / 双击的优先级**（M03P10）：`exclusively(before:)` 让双击先决 —— 单击只在
    /// 「没有第二下」之后才触发，所以双击播放时控制条不会先闪一下。
    func interactiveLayer(_ content: some View, size: CGSize) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .onEnded { _ in
                        // 双击 = 播放 / 暂停。
                        guard !shouldSwallowTap() else {
                            return
                        }
                        Task { await togglePlayback() }
                    }
                    .exclusively(
                        before: TapGesture(count: 1)
                            .onEnded { _ in
                                guard !shouldSwallowTap() else {
                                    return
                                }
                                toggleControlsVisibility()
                            }
                    )
            )
            // 长按加速与点按**同时**识别：不用 `exclusively`，那会把正常单击也一起赔进去；
            // 长按松手后补发的那次点按由 `shouldSwallowTap()` 吞掉（见它的说明）。
            .simultaneousGesture(speedBoostGesture)
            .gesture(playerGesture(width: size.width))
    }

    /// 长按临时加速（M03P12）：按住画面 → 换成长按倍速；松手 → 回到用户那份倍速。
    ///
    /// 为什么串一个零距离拖动：`LongPressGesture` 自己的 `onEnded` 在**识别成功**时就发
    /// （按住够 0.5 秒那一刻），拿不到「松手」；串完整个序列跟着手指结束，`onEnded` 才是松手。
    private var speedBoostGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.speedBoostHoldSeconds, maximumDistance: Self.speedBoostMaxDistance)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                // 长按已识别（`.first(true)`；紧接着的 `.second` 也兜一下）→ 开加速。
                // `beginSpeedBoost()` 自己有守卫，重复调用无副作用；拖动阶段这里不做事。
                switch value {
                case .first(true), .second(true, _):
                    beginSpeedBoost()
                default:
                    break
                }
            }
            .onEnded { _ in endSpeedBoost() }
    }

    /// 拖动：进度 / 亮度 / 音量三选一。加速期间整条拖动不做事
    /// （上游同款：`changeSpeed` 时 `onScroll` 直接 return —— 按住加速的手指抖一下不该变成拖进度）。
    private func playerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !isSpeedBoostHolding else {
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height
                let mode = gestureDrag ?? Self.dragMode(dx: dx, dy: dy, startX: value.startLocation.x, width: width)
                gestureDrag = mode
                switch mode {
                case .seek:
                    let base = gestureBasePosition ?? latestPosition
                    gestureBasePosition = base
                    let target = Self.seekTarget(base: base, dx: dx, width: width, duration: latestDuration)
                    gestureHint = "\(Self.timeText(target)) / \(Self.timeText(latestDuration))"
                case .brightness:
                    // 拿不到亮度（macOS 没有公开 API）就整次拖动不做事 —— 不摆一个「拖了没反应」的假手势。
                    guard let base = gestureBaseBrightness ?? PlatformShims.screenBrightness() else {
                        return
                    }
                    gestureBaseBrightness = base
                    let target = Self.verticalValue(base: base, dy: dy, pointsForFullRange: Self.verticalPointsForFullRange)
                    PlatformShims.setScreenBrightness(target)
                    gestureHint = "亮度 \(Int((target * 100).rounded()))%"
                case .volume:
                    let base = gestureBaseVolume ?? volume
                    gestureBaseVolume = base
                    volume = Self.verticalValue(base: base, dy: dy, pointsForFullRange: Self.verticalPointsForFullRange)
                    gestureHint = "音量 \(Int((volume * 100).rounded()))%"
                }
            }
            .onEnded { value in
                guard !isSpeedBoostHolding else {
                    return
                }
                if gestureDrag == .seek, let base = gestureBasePosition {
                    // 进度：松手才 seek。
                    let target = Self.seekTarget(base: base, dx: value.translation.width, width: width, duration: latestDuration)
                    Task { await engine?.seek(to: target) }
                } else if gestureDrag == .volume, gestureBaseVolume != nil {
                    // 音量：松手才下发内核；亮度那边拖动中已经写进系统亮度了，这里没它的事。
                    let target = Float(volume)
                    Task { await engine?.setVolume(target) }
                }
                gestureBasePosition = nil
                gestureBaseVolume = nil
                gestureBaseBrightness = nil
                gestureDrag = nil
                gestureHint = ""
            }
    }

    // MARK: - 长按加速

    /// 长按识别到了：先记「这次触摸是长按」（拖动不做事、点按要吞 —— 不在播也一样），
    /// 能加速时才真把速度切过去（上游 `if (!player().isPlaying()) return;` 就是这一步）。
    ///
    /// 提示直接用倍速文本（`2.0x`，上游 `play_speed_hint` 同款），按住期间一直亮着；
    /// 加速到多少是**可调的**（M03P13：播放页「长按倍速」，上游 `speed_long_press`）。
    func beginSpeedBoost() {
        guard !isSpeedBoostHolding else {
            return
        }
        isSpeedBoostHolding = true
        guard Self.canStartSpeedBoost(isPlaying: playerState.isPlaying, isBoosting: isSpeedBoosting), let engine else {
            return
        }
        isSpeedBoosting = true
        gestureHint = SpeedSetting.format(longPressSpeed)
        let boost = longPressSpeed
        Task { await engine.setRate(boost) }
    }

    /// 松手：回到**用户那份**倍速（他把速度设成 1.5x 时按一下不该变成 1.0x）；
    /// 本来就没加速（不在播 / 没内核）就只是把长按状态收掉。
    func endSpeedBoost() {
        guard isSpeedBoostHolding else {
            return
        }
        isSpeedBoostHolding = false
        speedBoostEndedAt = Date()
        gestureHint = ""
        guard isSpeedBoosting else {
            return
        }
        isSpeedBoosting = false
        setSpeed(speed, persist: false)
    }

    /// 这次点按要不要吞掉：长按这次触摸还没结束（`simultaneousGesture` 不挡点按）、或刚松手那一下补发的。
    ///
    /// 为什么要吞：SwiftUI 的 `TapGesture` 没有「按多久算点按」的上限，长按松手后会补一次单击 ——
    /// 不吞的话「按住加速 → 松手」会把控制条闪一下（那是单击的副作用）。
    func shouldSwallowTap() -> Bool {
        if isSpeedBoostHolding {
            return true
        }
        guard let endedAt = speedBoostEndedAt else {
            return false
        }
        speedBoostEndedAt = nil
        return Date().timeIntervalSince(endedAt) < Self.speedBoostSwallowSeconds
    }
}
