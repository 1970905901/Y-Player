import CatVodPlayer
import Foundation
import SwiftUI

/// 播放页的「播放速度」区（M02P15 / M03P13）与「音量增益」区（M04P23）。
///
/// 排在这页的其它区一致（一行行文字）：范围 / 步进 / 预设 / 显示格式全对齐上游 `SpeedSetting`，
/// 外加一条「长按倍速」（M03P13）。上游那套里**还没做的只剩跳过静音**（要内核支持，见 M02P15）。
///
/// 音量增益（M04P23）也落在这儿：它跟倍速一样是「这一页的听感旋钮」，都摆在信息区、都不上控制条。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数离 SwiftLint 的 `file_length` error（800）只剩十几行 ——
/// 与 `PlaybackView+Overlays` / `+Stats` / `+Gestures` / `+OpeningEnding` 同一套做法；
/// 跨文件用到的成员（`speed` / `longPressSpeed` / `engine`）本来就已经是模块内。
extension PlaybackView {
    /// 「播放速度」区：当前值 + 预设 + 恢复。
    ///
    /// 排版跟本页其它区一致（一行行文字），因为画面交给系统原生 `VideoPlayer`，我们不自绘播放控件
    /// （`docs/UI 规范.md`）。范围/步进/预设与显示格式全部对齐上游 `SpeedSetting`；
    /// 上游那套里**还没做的只剩「跳过静音」**（要内核支持，见 M02P15）——「长按倍速」在 M03P13 接上。
    var speedSection: some View {
        Section("播放速度") {
            HStack {
                Text(SpeedSetting.format(speed))
                    .monospacedDigit()
                Spacer()
                Button("恢复 1.0x") {
                    setSpeed(SpeedSetting.normal, persist: true)
                }
                .disabled(SpeedSetting.isNormal(speed))
            }
            Slider(
                value: speedSlider,
                in: SpeedSetting.minimum ... SpeedSetting.maximum,
                step: SpeedSetting.step,
                onEditingChanged: { editing in
                    // 拖动过程中已经即时生效；松手才落盘（一次拖动几十个中间值，不必写几十次 UserDefaults）。
                    guard !editing else { return }
                    PlaybackSpeedBook.save(speed)
                }
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpeedSetting.presets, id: \.self) { preset in
                        Button(SpeedSetting.format(preset)) {
                            setSpeed(preset, persist: true)
                        }
                        .buttonStyle(.bordered)
                        .tint(SpeedSetting.isSame(preset, speed) ? .accentColor : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text("长按倍速")
                Spacer()
                Text(SpeedSetting.format(longPressSpeed))
                    .monospacedDigit()
                Button("恢复 \(SpeedSetting.format(SpeedSetting.longPress))") {
                    setLongPressSpeed(SpeedSetting.longPress)
                }
                .disabled(SpeedSetting.isSame(longPressSpeed, SpeedSetting.longPress))
            }
            Slider(
                value: longPressSpeedSlider,
                in: SpeedSetting.longPressMinimum ... SpeedSetting.maximum,
                step: SpeedSetting.longPressStep
            )
        }
    }

    /// 滑杆绑定：拖动中即时生效（改倍速要能马上听出来）。
    var speedSlider: Binding<Float> {
        Binding(
            get: { speed },
            set: { newValue in setSpeed(newValue, persist: false) }
        )
    }

    /// 长按倍速滑杆：只有 7 档（2.0–5.0、步进 0.5），**不用等松手** —— 每一档都写一次存档也不心疼。
    var longPressSpeedSlider: Binding<Float> {
        Binding(
            get: { longPressSpeed },
            set: { newValue in setLongPressSpeed(newValue) }
        )
    }

    /// 改倍速的**唯一出口**：夹紧 → 记进界面 →（可选）落盘 → 下发内核。
    /// 长按加速松手也走这里回到用户那份倍速（M03P12）—— 跨文件扩展要用，所以是模块内。
    func setSpeed(_ value: Float, persist: Bool) {
        let target = SpeedSetting.clamp(value)
        speed = target
        if persist {
            PlaybackSpeedBook.save(target)
        }
        guard let engine else {
            return
        }
        Task { await engine.setRate(target) }
    }

    /// 改长按倍速的**唯一出口**（M03P13）：夹紧 → 记进界面 → 落盘。
    /// **不下发内核**：它只影响下一次长按，当前正在播的速度不该被它改。
    func setLongPressSpeed(_ value: Float) {
        let target = SpeedSetting.clampLongPress(value)
        longPressSpeed = target
        PlaybackSpeedBook.saveLongPressSpeed(target)
    }

    /// 「音量增益」区（M04P23）：当前值 + 恢复 + 滑杆，形态与「播放速度」一致。
    ///
    /// 只在 ``PlayerEngineKind/supportsAudioGain`` 的内核上摆（系统内核 `AVPlayer.volume` 封顶 1，
    /// 放大不了）—— 拿不到就不摆，不给假滑杆（与画面比例 / 解码方式同一条规矩）。
    var audioGainSection: some View {
        Section("音量增益") {
            HStack {
                Text(AudioGain.format(audioGain))
                    .monospacedDigit()
                Spacer()
                Button("恢复 \(AudioGain.format(AudioGain.minimum))") {
                    setAudioGain(AudioGain.minimum)
                }
                .disabled(audioGain == AudioGain.minimum)
            }
            Slider(
                value: audioGainSlider,
                in: AudioGain.minimum ... AudioGain.maximum,
                step: AudioGain.step
            )
        }
    }

    /// 增益滑杆绑定：拖动中即时生效（放大多少要能马上听出来）；**页面内偏好，不落盘**。
    var audioGainSlider: Binding<Float> {
        Binding(
            get: { audioGain },
            set: { newValue in setAudioGain(newValue) }
        )
    }

    /// 改增益的**唯一出口**：夹紧 → 记进界面 → 下发内核（`AudioGain.clamp` 在引擎侧还会再挡一道）。
    func setAudioGain(_ value: Float) {
        let target = AudioGain.clamp(value)
        audioGain = target
        guard let engine else {
            return
        }
        Task { await engine.setAudioGain(target) }
    }
}
