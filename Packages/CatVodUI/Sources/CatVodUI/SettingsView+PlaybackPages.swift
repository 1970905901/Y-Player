import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

// 设置页的「播放」子页。
//
// 约定（与 `docs/任务记录/M02P11-设置页与追剧页.md` 一致）：
// 能用真实数据的就用真实数据；暂时没有的一律**写明缺什么 + 属于哪个里程碑**，
// 不静默失败、也不做「点了没反应」的假开关。

// MARK: - 播放器

/// 播放器：默认播放器 + 三个子页（内核 / 播放界面 / 播放控制）。
///
/// 结构对齐参考图：第一行是「默认播放器 + 当前值」，下面三行都是导航行。
/// 参考图第一行下面那个 `KPlayer` 是它自带的第三方内核名；我们这里第一行就是**当前内核**的名字
/// （系统播放器 / MPV / 自研 FFmpeg），点进去是内核与解码设置 —— 与「源地址 → 接口管理」
/// 共用 ``PlaybackSettingsSection``，不会出现两处显示不一致。
@MainActor
struct SettingsPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                HStack {
                    Text("默认播放器")
                    Spacer()
                    Text(model.preferredEngine.displayName)
                        .foregroundStyle(PlatformShims.accent)
                }
                NavigationLink {
                    SettingsPlayerEngineView(model: model)
                } label: {
                    Text(model.preferredEngine.displayName)
                }
                NavigationLink {
                    SettingsPlayerUISettingsView(model: model)
                } label: {
                    Text("播放界面")
                }
                NavigationLink {
                    SettingsPlayerControlView(model: model)
                } label: {
                    Text("播放控制")
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放器")
    }
}

/// 播放内核：内核 + 解码方式 + 本地代理（与接口管理页共用同一区块）。
@MainActor
struct SettingsPlayerEngineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackSettingsSection(model: model)
        }
        .adaptiveListStyle()
        .navigationTitle("播放内核")
    }
}

/// 播放界面：播放页的显示方式。
///
/// 与「设置 → 播放 → 播放页」共用 ``PlaybackPageSettingsSection``，
/// 避免两处各写一份 Picker 而出现「两个页面显示的视图不一样」。
@MainActor
struct SettingsPlayerUISettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackPageSettingsSection(model: model)
            Section("说明") {
                Text("播放页的画面控件与手势由系统播放器提供（`docs/UI 规范.md`：不自绘播放控件），"
                    + "所以这里没有「渲染方式 / 音视频轨道 / 字幕样式」这类内核专属设置；"
                    + "M3（MPVKit）/ M4（自研 FFmpeg）接入后会补上。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放界面")
    }
}

/// 播放控制：现在的控制从哪来、以后会加什么。
@MainActor
struct SettingsPlayerControlView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section("当前形态") {
                InfoRow(title: "控制方式", value: "系统播放器")
                InfoRow(title: "当前内核", value: model.preferredEngine.displayName)
                InfoRow(title: "倍速", value: "播放页「播放速度」区（0.1x–5.0x，含预设）")
                Text("播放 / 暂停、进度拖动、全屏、画中画、后台播放与手势都由系统播放器提供，我们不自绘 —— 除倍速外没有其它可调项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("后续") {
                Text("M3（MPVKit）/ M4（自研 FFmpeg）接入后，这里会出现内核专属控制：手势映射、逐帧步进、音频增益等。上游的「长按屏幕临时加速」要接管手势、与系统播放器自带手势冲突，暂不做（见 M02P15）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放控制")
    }
}

// MARK: - 播放页

/// 播放页：显示视图 + 自动播放。
///
/// 结构对齐参考图的两行：`显示视图`（点开是「精简视图 / Emby 视图」菜单）与
/// `自动播放`（副标题「首次进入是否自动选中第一集开始播放」）。
///
/// 两项都是**真实生效**的偏好：显示视图决定详情页的排布，
/// 自动播放决定进入详情页后是否直接开播（有「上次看到」的进度时以续播为准）。
@MainActor
struct SettingsPlaybackPageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackPageSettingsSection(model: model)
            Section("说明") {
                Text("显示视图只换排布，数据与交互不变：\(model.playbackPageLayout.summary)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("自动播放只在「没有观看记录」时生效；有记录时按记录续播，不会把用户拉回第一集。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放页")
    }
}

/// 播放页设置区块：显示视图 + 自动播放。
///
/// 两个入口共用（避免两处各写一份 Picker）：
/// - 设置 → 播放 → 播放页（``SettingsPlaybackPageView``）；
/// - 设置 → 播放 → 播放器 → 播放界面（``SettingsPlayerUISettingsView``）。
@MainActor
struct PlaybackPageSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Picker("显示视图", selection: $model.playbackPageLayout) {
                ForEach(PlaybackPageLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $model.autoPlayFirstEpisode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动播放")
                    Text("首次进入是否自动选中第一集开始播放")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 弹幕 API（解析器）

/// 弹幕显示：字号 / 透明度 / 速度 / 显示区域（M08i）。
///
/// 四项都**即时生效**：改一次写一次 `UserDefaults`，播放页重排计划时读到 ——
/// 播放中把字号调大，下一帧就变大，不用退出重进。
///
/// 为什么给一行「预览」：字号和透明度光看数字判断不了合不合适。预览用的是**同一份**
/// `DanmakuDisplayStyle`（只差「画面尺寸」这一项），所以预览什么样、屏上就什么样。
@MainActor
struct SettingsDanmakuDisplayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                Text("这里只管**本机的显示**：弹幕从哪儿取见「弹幕 API」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("这是一条弹幕预览")
                    .font(.system(size: previewFontSize))
                    .opacity(model.danmakuDisplay.opacity)
                    .lineLimit(1)
            } header: {
                Text("预览")
            } footer: {
                Text("视频上的弹幕会与此同步（实际字号还会按视频区的高度再缩放一次，"
                    + "以免大屏上显得太小）。")
            }

            Section {
                HStack {
                    Text("倍率")
                    Spacer()
                    Text(String(format: "%.1f×", model.danmakuDisplay.fontScale))
                        .foregroundStyle(.secondary)
                }
                Slider(value: fontScaleBinding, in: DanmakuDisplayConfig.fontScaleRange, step: 0.1) {
                    Text("字号")
                }
            } header: {
                Text("字号")
            } footer: {
                Text("按弹幕自带的字号（常见 25）缩放。\(rangeText(DanmakuDisplayConfig.fontScaleRange))")
            }

            Section {
                HStack {
                    Text("不透明度")
                    Spacer()
                    Text(String(format: "%.0f%%", model.danmakuDisplay.opacity * 100))
                        .foregroundStyle(.secondary)
                }
                Slider(value: opacityBinding, in: DanmakuDisplayConfig.opacityRange, step: 0.05) {
                    Text("透明度")
                }
            } header: {
                Text("透明度")
            } footer: {
                Text("弹幕太亮会盖住画面，压低一点更耐看。")
            }

            Section {
                Picker("速度", selection: speedBinding) {
                    ForEach(DanmakuSpeed.allCases, id: \.self) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("速度")
            } footer: {
                Text("一条弹幕划过整屏的秒数：慢 \(seconds(DanmakuSpeed.slow)) / 中 "
                    + "\(seconds(DanmakuSpeed.normal)) / 快 \(seconds(DanmakuSpeed.fast))。"
                    + "越慢，同一时刻屏上的弹幕越多。")
            }

            Section {
                Picker("显示区域", selection: areaBinding) {
                    ForEach(DanmakuArea.allCases, id: \.self) { area in
                        Text(area.title).tag(area)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("显示区域")
            } footer: {
                Text("弹幕占屏幕高度多少（从顶部算）。压到半屏以内，能少糊住画面下方与字幕。")
            }
        }
        .adaptiveListStyle()
        .navigationTitle("弹幕显示")
    }

    /// 预览字号：按典型字号（25）× 当前倍率，**不**按画面尺寸缩放 ——
    /// 预览里没有「视频区尺寸」这个概念，用基准比例最接近手机上的实际观感。
    private var previewFontSize: CGFloat {
        CGFloat(DanmakuDisplayStyle.typicalFontSize * model.danmakuDisplay.fontScale)
    }

    private func seconds(_ speed: DanmakuSpeed) -> String {
        String(format: "%.0f 秒", speed.scrollDuration)
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        String(format: "%.1f× … %.1f×", range.lowerBound, range.upperBound)
    }

    /// 字号绑定：写入时再夹一次范围。
    ///
    /// `Slider` 的 `in:` 已经保证了范围，但**写进配置**这一步不该依赖界面控件守规矩 ——
    /// 与 `DanmakuAPIConfig.setAddress` 越界忽略是同一个道理。
    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { model.danmakuDisplay.fontScale },
            set: { model.danmakuDisplay.fontScale = DanmakuDisplayConfig.clamp($0, to: DanmakuDisplayConfig.fontScaleRange) }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { model.danmakuDisplay.opacity },
            set: { model.danmakuDisplay.opacity = DanmakuDisplayConfig.clamp($0, to: DanmakuDisplayConfig.opacityRange) }
        )
    }

    private var speedBinding: Binding<DanmakuSpeed> {
        Binding(
            get: { model.danmakuDisplay.speed },
            set: { model.danmakuDisplay.speed = $0 }
        )
    }

    private var areaBinding: Binding<DanmakuArea> {
        Binding(
            get: { model.danmakuDisplay.area },
            set: { model.danmakuDisplay.area = $0 }
        )
    }
}

/// 弹幕 API：启用开关 + 四个地址槽位（结构对齐参考图）。
///
/// 参考图的做法是「用户自己填 1…4 个弹幕接口地址」，副标题写明「开启后将禁用视频源的弹幕功能」。
/// 我们这里把地址**真实保存**（`UserDefaults`，重启后仍在）：取回见 M08c、上屏见 M08h，
/// 填好地址进播放页就会有弹幕。显示参数（字号 / 透明度 / 速度 / 区域）在「弹幕显示」页。
///
/// 配置里声明的解析器（`parses`）另列一组：那是「这个源能解析什么」，
/// 与「用户自选弹幕 API」是两件事，不该混在一处展示。
@MainActor
struct SettingsDanmakuAPIView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                Toggle(isOn: $model.danmakuAPI.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用弹幕 API")
                        Text("开启后将禁用视频源的弹幕功能")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 四个槽位各成一组（对齐参考图的 `API-1` … `API-4`）：顺序固定，不随输入变化。
            ForEach(0 ..< DanmakuAPIConfig.slotCount, id: \.self) { index in
                Section("API-\(index + 1)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API-\(index + 1)")
                        TextField("API 地址", text: addressBinding(index))
                    }
                }
            }

            Section("说明") {
                Text("四个地址保存在本机（重启后仍在）。填好地址并启用后，进播放页就会去搜索并上屏"
                    + "（取回见 M08c、上屏见 M08h）；显示参数在「弹幕显示」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if parsers.isEmpty {
                Section("接口解析器（parses）") {
                    Text(emptyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("接口解析器（parses）") {
                    ForEach(parsers) { parser in
                        row(for: parser)
                    }
                }
            }

            Section("现状") {
                Text("解析链本身（`parse`/`jx`）与 Web 嗅探在 M5 实现，弹幕与字幕的渲染在 M8。也就是说：这里能看到接口声明了哪些解析器，但播放时还不会自动去调它们。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("弹幕 API")
    }

    /// 某个槽位的地址绑定：读写在 `AppModel.danmakuAPI` 上（`@Published`，写一次就落 `UserDefaults`）。
    private func addressBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.danmakuAPI.address(at: index) },
            set: { model.danmakuAPI.setAddress($0, at: index) }
        )
    }

    private func row(for parser: ParserRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parser.name.isEmpty ? "未命名解析器" : parser.name)
                Spacer()
                Text(kindText(parser))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !parser.url.isEmpty {
                Text(parser.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let reason = parser.availability.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var parsers: [ParserRule] {
        model.state.loadedSource?.config.parses ?? []
    }

    /// 解析器类型的中文名（JAR 两类明确标注不支持）。
    ///
    /// 注意两点（都是 lint 约定）：
    /// - `switch` 表达式的隐式返回只允许出现在「整个函数体就是那一个表达式」时，这里前面还有语句，所以每条分支显式 `return`；
    /// - 不在 `switch` 里做可选值匹配（`case .some(.web)`），先 `guard let` 拿到非可选枚举再分支。
    private func kindText(_ parser: ParserRule) -> String {
        guard let kind = parser.kind else {
            return "type=\(parser.type)"
        }
        switch kind {
        case .web:
            return "Web 嗅探"
        case .json:
            return "JSON 解析"
        case .jarJson:
            return "JAR Json（不支持）"
        case .jarMix:
            return "JAR Mix（不支持）"
        case .aggregate:
            return "聚合解析"
        }
    }

    private var emptyHint: String {
        if let reason = model.state.failureReason {
            return "接口加载失败：\(reason)"
        }
        return "当前接口没有解析器（`parses` 为空），或还没有加载接口。"
    }
}
