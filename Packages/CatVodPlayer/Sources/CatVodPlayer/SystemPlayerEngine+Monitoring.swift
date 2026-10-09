import AVFoundation
import CatVodCore
import Foundation

// 系统内核的就绪轮询与事件观测。
//
// 这些方法都属于 `AVPlayerEngine`（`@MainActor` 类），因此全部在主线程执行，符合 AVFoundation 的线程模型。

/// 就绪轮询的判定结果（避免把非 Sendable 的 `AVPlayerItem` 捕获进 `Task`）。
enum PlaybackStatusDecision {
    case pending
    case ready
    case failed(String)
}

extension AVPlayerEngine {
    func installObservers(item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                self?.handleTick(seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEnd()
            }
        }
    }

    func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled, Date() < deadline {
                guard let self else {
                    return
                }
                switch pollStatus() {
                case .ready:
                    handleReady()
                    return
                case let .failed(reason):
                    handleFailure(reason)
                    return
                case .pending:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            self?.handleFailure("加载超时（20 秒内未就绪）")
        }
    }

    func pollStatus() -> PlaybackStatusDecision {
        guard let item = player.currentItem else {
            return .failed("播放项未建立")
        }
        switch item.status {
        case .readyToPlay:
            return .ready
        case .failed:
            return .failed(item.error?.localizedDescription ?? "未知错误")
        case .unknown:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func handleReady() {
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        player.play()
        update(.playing)
        emit(.timeChanged(current: lastTime, duration: duration))
        // 轨道列表就绪后才拿得到（M03P7）：播放页的「轨道」区靠它出现。
        reportTracks()
    }

    func handleFailure(_ reason: String) {
        update(.failed(reason))
        emit(.error(reason))
    }

    func handleTick(_ seconds: Double) {
        lastTime = seconds
        if duration <= 0 {
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
        }
        emit(.timeChanged(current: seconds, duration: duration))
    }

    func handleEnd() {
        update(.ended)
    }
}
