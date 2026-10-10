import CatVodPlayer
import SwiftUI

/// 播放页自绘内核的**控制条**（M03P6 起，M03P21 加锁屏按钮）。
///
/// 为什么必须自绘：系统内核的控件是 `VideoPlayer` 自带的；自绘内核（MPV / 自研 FFmpeg）只有一层画面层，
/// 没有这条就只能看，不能停、不能拖。变速 / 画面比例这些在信息区，控制条只留最常用的几个。
///
/// 锁屏（M03P21）也落在这一条上：锁上之后**常规内容整块藏起来，只剩锁按钮** ——
/// 上游 `control.right.lock` 同款。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Speed` / `+Gestures` / `+OpeningEnding` / `+Lines` 同一套做法。
///
/// 逐帧步进按钮（M04P23）也落在这一条上：播放 / 暂停旁边，播放中按 = 内核先暂停再走一帧。
extension PlaybackView {
    /// 最小控制条：播放 / 暂停 + 进度 + 时间（变速 / 画面比例在信息区，不在这儿）。
    var playerControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if !isLocked {
                    playbackControls
                }
                lockButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))
        }
    }

    /// 控制条的常规内容：播放 / 暂停 + 进度 + 时间（锁上时整块藏起来，只剩 ``lockButton``）。
    var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerState.isPlaying ? "暂停" : "播放")

            Button {
                Task { await engine?.stepFrame() }
            } label: {
                Image(systemName: "forward.frame")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("逐帧步进")

            Text(Self.timeText(latestPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
            Slider(
                value: seekBinding,
                in: 0 ... max(latestDuration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    guard !editing else { return }
                    // 松手才 seek：一次拖动会产生几十个中间值，逐个 seek 会把内核打爆。
                    let target = latestPosition
                    Task { await engine?.seek(to: target) }
                    // 跟控制条交互过：自动收起的计时从头算（M03P10）。
                    scheduleControlsAutoHide()
                }
            )
            .tint(.white)
            Text(Self.timeText(latestDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    /// 锁 / 解锁按钮（M03P21）：锁上之后控制条只剩它 —— 上游 `control.right.lock` 同款，
    /// 点一下切换，并把控制条亮出来（免得刚锁上那条就自己收起来了）。
    var lockButton: some View {
        Button {
            isLocked.toggle()
            showControls()
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocked ? "解锁" : "锁定画面")
    }

    /// 进度条绑定：拖动只改界面上的位置（松手才真 seek，见 ``playerControls`` 的 `onEditingChanged`）。
    var seekBinding: Binding<Double> {
        Binding(
            get: { latestPosition },
            set: { newValue in latestPosition = newValue }
        )
    }
}
