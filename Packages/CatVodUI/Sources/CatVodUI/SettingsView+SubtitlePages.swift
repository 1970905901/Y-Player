import Foundation
import SwiftUI

// 设置页的「字幕」子页（M09g）。
//
// 单独一个文件而不是塞进 `SettingsView+PlaybackPages.swift`：那个文件已经装了播放器 / 播放页 /
// 弹幕 API / 弹幕显示四页，字幕显示与它们没有耦合（只读写 `AppModel.subtitleDisplay`）。

/// 字幕显示：开关 / 字号 / 位置 / 背景（M09g）。
///
/// 四项都**即时生效**：改一次写一次 `UserDefaults`，播放页下一帧就按新参数画（与弹幕显示设置
/// 同一套做法）。
///
/// 预览那一块是**按比例缩小的小画面**：位置与背景这两项放进一个缩小的视频块里看，
/// 比读「低 / 中 / 高」三个字直观得多。它用的是**同一份** `SubtitleDisplayStyle`，
/// 只把高度换成预览块的高度。
@MainActor
struct SettingsSubtitleDisplayView: View {
    @ObservedObject var model: AppModel

    /// 预览块的高度（按播放页的视频区比例缩一点）。
    private static let previewHeight: CGFloat = 110

    var body: some View {
        List {
            Section {
                Text("这里只管**本机的显示**：字幕从哪儿取取决于站点结果（`subs`）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("显示字幕", isOn: visibleBinding)
            } footer: {
                Text("关掉之后屏上立刻不显示 —— 字幕已经取回来也照样不画。")
            }

            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.previewHeight)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            } header: {
                Text("预览")
            } footer: {
                Text("位置与背景在这里是什么样，视频上就是什么样（实际字号还会按视频区的高度再缩放一次）。")
            }

            Section {
                HStack {
                    Text("倍率")
                    Spacer()
                    Text(String(format: "%.1f×", model.subtitleDisplay.fontScale))
                        .foregroundStyle(.secondary)
                }
                Slider(value: fontScaleBinding, in: SubtitleDisplayConfig.fontScaleRange, step: 0.1) {
                    Text("字号")
                }
            } header: {
                Text("字号")
            } footer: {
                Text("字幕整体大小的倍率。\(rangeText(SubtitleDisplayConfig.fontScaleRange))")
            }

            Section {
                Picker("位置", selection: positionBinding) {
                    ForEach(SubtitlePosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("位置")
            } footer: {
                Text("字幕离画面底边多远。画面下方有字幕挡住的画面内容（水印、人脸）时往外挪一档。")
            }

            Section {
                Picker("背景", selection: backgroundBinding) {
                    ForEach(SubtitleBackground.allCases, id: \.self) { background in
                        Text(background.title).tag(background)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("背景")
            } footer: {
                Text("字幕常压在亮色画面上：半透明黑底最好读；画面特别花时可以选「深色」。")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("字幕显示")
    }

    /// 预览：把当前参数放进一个小画面里。
    ///
    /// 字号走**同一份** `resolved(height:)`（只把高度换成预览块的高度）—— 预览与屏上不会走两套
    /// 算路，这是「预览什么样、屏上就什么样」的前提。
    private var preview: some View {
        let style = model.subtitleDisplay.style.resolved(height: Double(Self.previewHeight))
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("这是一条字幕预览")
                .font(.system(size: CGFloat(style.fontSize)))
                .lineSpacing(CGFloat(style.lineSpacing))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Color.black.opacity(style.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .opacity(style.opacity)
                .padding(.bottom, CGFloat(style.bottomInset))
        }
        .padding(.horizontal, 12)
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        String(format: "%.1f× … %.1f×", range.lowerBound, range.upperBound)
    }

    private var visibleBinding: Binding<Bool> {
        Binding(
            get: { model.subtitleDisplay.isVisible },
            set: { model.subtitleDisplay.isVisible = $0 }
        )
    }

    /// 字号绑定：写入时再夹一次范围。
    ///
    /// `Slider` 的 `in:` 已经保证了范围，但**写进配置**这一步不该依赖界面控件守规矩 ——
    /// 与 `DanmakuDisplayConfig` / `DanmakuAPIConfig` 同一套理由。
    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { model.subtitleDisplay.fontScale },
            set: { model.subtitleDisplay.fontScale = SubtitleDisplayConfig.clamp($0, to: SubtitleDisplayConfig.fontScaleRange) }
        )
    }

    private var positionBinding: Binding<SubtitlePosition> {
        Binding(
            get: { model.subtitleDisplay.position },
            set: { model.subtitleDisplay.position = $0 }
        )
    }

    private var backgroundBinding: Binding<SubtitleBackground> {
        Binding(
            get: { model.subtitleDisplay.background },
            set: { model.subtitleDisplay.background = $0 }
        )
    }
}
