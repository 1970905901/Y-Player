import CatVodCore
import SwiftUI

/// 弹幕显示配置的五个**带夹紧**的绑定（M03P24）。
///
/// 为什么单独立一件：设置页「弹幕显示」与播放页「弹幕设置」快捷面板是**同一份配置的两个面** ——
/// 范围、写回时再夹一次这些规则只该有一处实现（两个界面各写一遍，迟早走样）。
struct DanmakuDisplayBindings {
    let config: Binding<DanmakuDisplayConfig>

    var isVisible: Binding<Bool> {
        Binding(
            get: { config.wrappedValue.isVisible },
            set: { config.wrappedValue.isVisible = $0 }
        )
    }

    /// 字号：写回时再夹一次范围。
    ///
    /// `Slider` 的 `in:` 已经保证了范围，但**写进配置**这一步不该依赖界面控件守规矩 ——
    /// 与 `DanmakuAPIConfig.setAddress` 越界忽略是同一个道理（M08i 的原话）。
    var fontScale: Binding<Double> {
        Binding(
            get: { config.wrappedValue.fontScale },
            set: { config.wrappedValue.fontScale = DanmakuDisplayConfig.clamp($0, to: DanmakuDisplayConfig.fontScaleRange) }
        )
    }

    var opacity: Binding<Double> {
        Binding(
            get: { config.wrappedValue.opacity },
            set: { config.wrappedValue.opacity = DanmakuDisplayConfig.clamp($0, to: DanmakuDisplayConfig.opacityRange) }
        )
    }

    var speed: Binding<DanmakuSpeed> {
        Binding(
            get: { config.wrappedValue.speed },
            set: { config.wrappedValue.speed = $0 }
        )
    }

    var area: Binding<DanmakuArea> {
        Binding(
            get: { config.wrappedValue.area },
            set: { config.wrappedValue.area = $0 }
        )
    }

    /// 恢复默认：把**显示参数**（字号 / 透明度 / 速度 / 区域）拉回出厂值。
    ///
    /// 总开关不动 —— 上游那张面板的分页恢复也不碰它（总开关归播放页那颗「显示弹幕」管）。
    func reset() {
        let defaults = DanmakuDisplayConfig()
        var next = config.wrappedValue
        next.fontScale = defaults.fontScale
        next.opacity = defaults.opacity
        next.speed = defaults.speed
        next.area = defaults.area
        config.wrappedValue = next
    }
}

/// 「弹幕显示」的全部旋钮（M03P24）：设置页「弹幕显示」与播放页「弹幕设置」**共用这一组控件**。
///
/// 只能放进 `List` / `Form` —— 它发的是一组 `Section`，那就是两个界面的共同骨架。
/// `showsExplanations` 只控制要不要附解释文字：设置页有地方写，半屏面板没有
/// （与 `PlaybackSettingsSection` 当年抽出来是同一个理由：同一样东西别在两地各写一份）。
struct DanmakuDisplayControls: View {
    @Binding var config: DanmakuDisplayConfig
    var showsExplanations = true

    private var bindings: DanmakuDisplayBindings {
        DanmakuDisplayBindings(config: $config)
    }

    var body: some View {
        Section {
            Toggle("显示弹幕", isOn: bindings.isVisible)
        } header: {
            Text("显示")
        } footer: {
            if showsExplanations {
                Text("关掉之后整层不画。播放页里也能就地开关（同一份配置）。")
            }
        }

        Section {
            Text("这是一条弹幕预览")
                .font(.system(size: previewFontSize))
                .opacity(config.opacity)
                .lineLimit(1)
        } header: {
            Text("预览")
        } footer: {
            if showsExplanations {
                Text("视频上的弹幕会与此同步（实际字号还会按视频区的高度再缩放一次，"
                    + "以免大屏上显得太小）。")
            }
        }

        Section {
            HStack {
                Text("倍率")
                Spacer()
                Text(String(format: "%.1f×", config.fontScale))
                    .foregroundStyle(.secondary)
            }
            Slider(value: bindings.fontScale, in: DanmakuDisplayConfig.fontScaleRange, step: 0.1) {
                Text("字号")
            }
        } header: {
            Text("字号")
        } footer: {
            if showsExplanations {
                Text("按弹幕自带的字号（常见 25）缩放。\(rangeText(DanmakuDisplayConfig.fontScaleRange))")
            }
        }

        Section {
            HStack {
                Text("不透明度")
                Spacer()
                Text(String(format: "%.0f%%", config.opacity * 100))
                    .foregroundStyle(.secondary)
            }
            Slider(value: bindings.opacity, in: DanmakuDisplayConfig.opacityRange, step: 0.05) {
                Text("透明度")
            }
        } header: {
            Text("透明度")
        } footer: {
            if showsExplanations {
                Text("弹幕太亮会盖住画面，压低一点更耐看。")
            }
        }

        Section {
            Picker("速度", selection: bindings.speed) {
                ForEach(DanmakuSpeed.allCases, id: \.self) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("速度")
        } footer: {
            if showsExplanations {
                Text("一条弹幕划过整屏的秒数：慢 \(seconds(DanmakuSpeed.slow)) / 中 "
                    + "\(seconds(DanmakuSpeed.normal)) / 快 \(seconds(DanmakuSpeed.fast))。"
                    + "越慢，同一时刻屏上的弹幕越多。")
            }
        }

        Section {
            Picker("显示区域", selection: bindings.area) {
                ForEach(DanmakuArea.allCases, id: \.self) { area in
                    Text(area.title).tag(area)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("显示区域")
        } footer: {
            if showsExplanations {
                Text("弹幕占屏幕高度多少（从顶部算）。压到半屏以内，能少糊住画面下方与字幕。")
            }
        }
    }

    /// 预览字号：按典型字号（25）× 当前倍率，**不**按画面尺寸缩放 ——
    /// 预览里没有「视频区尺寸」这个概念，用基准比例最接近手机上的实际观感。
    private var previewFontSize: CGFloat {
        CGFloat(DanmakuDisplayStyle.typicalFontSize * config.fontScale)
    }

    private func seconds(_ speed: DanmakuSpeed) -> String {
        String(format: "%.0f 秒", speed.scrollDuration)
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        String(format: "%.1f× … %.1f×", range.lowerBound, range.upperBound)
    }
}
