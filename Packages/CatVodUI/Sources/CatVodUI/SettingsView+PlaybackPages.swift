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

/// 播放器：默认播放器（点开是内核菜单，就地切换）+ 三个子页（内核 / 播放界面 / 播放控制）。
///
/// 结构对齐参考图：第一行是「默认播放器 + 当前值（蓝字）」，**点它出内核菜单** ——
/// 此前这里只是个死标签（点蓝字没反应，真正的入口是下面一行重名的内核名），用户报过这一处。
/// 第二行「内核」进去是内核与解码设置 —— 与「源地址 → 接口管理」共用 ``PlaybackSettingsSection``。
@MainActor
struct SettingsPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                // 第一行既是「当前值」，也是切换入口：点它出内核菜单（此前是个死标签 ——
                // 点蓝字没反应，真正的入口是下面一行重名的内核名；用户报过这一处）。
                Menu {
                    Picker("默认播放器", selection: $model.preferredEngine) {
                        ForEach(PlayerEngineKind.allCases, id: \.self) { kind in
                            Text(kind.settingsTitle).tag(kind)
                        }
                    }
                } label: {
                    HStack {
                        // 显式定色：Menu 会把自己的 tint 刷到整个 label 上 —— 不加这一句，
                        // 左半边「默认播放器」也会变蓝（用户截图指出，只有右侧的值该是蓝的）。
                        Text("默认播放器")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text(model.preferredEngine.displayName)
                            .foregroundStyle(PlatformShims.accent)
                    }
                    .contentShape(Rectangle())
                }
                NavigationLink {
                    SettingsPlayerEngineView(model: model)
                } label: {
                    Text("内核")
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
            } footer: {
                // 这一页的第一行就是换内核的入口 —— 生效时机那句话在这里也得有（M24P1）。
                Text(PlaybackSettingsSection.appliesOnNextPlaybackNote)
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
                Text("系统内核（AVPlayer）的画面控件与手势由系统提供（`docs/UI 规范.md`：不自绘播放控件）；"
                    + "MPV 与自研 FFmpeg 内核共用自绘的最小控制条与手势（双击暂停 / 横拖进度 / 纵拖音量），"
                    + "MPV 的音轨与字幕在播放页选。自研 FFmpeg 内核（M04P13 起可播）严格按设置的解码方式："
                    + "硬解不可用时播放页会明确提示、让你改成软解（不自动降级）；音轨与内嵌文本字幕都能在播放页换"
                    + "（字幕只出字、样式不还原，位图轨不做，见 M04P19）。")
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

    /// 控制方式一行：跟着**当前选的内核**走，别写死「系统播放器」（那行以前就是这么过期的）。
    private var controlSummary: String {
        switch model.preferredEngine {
        case .system: "系统播放器（AVPlayer）"
        case .mpv: "MPV 自带最小控制条 + 播放页手势"
        case .ffmpeg: "自研 FFmpeg（自绘最小控制条 + 播放页手势）"
        }
    }

    /// 控制从哪来：两套内核各自说清（系统内核全交给系统；MPV 只有最小控制条 + 手势）。
    private var controlDetail: String {
        switch model.preferredEngine {
        case .system:
            "播放 / 暂停、进度拖动、全屏、画中画、后台播放与手势都由系统播放器提供，我们不自绘 —— 除倍速外没有其它可调项。"
        case .mpv:
            "MPV 的画面由我们自己渲染（MoltenVK → Metal），只配了一条最小控制条（播放 / 暂停、进度、倍速、音轨 / 字幕）；"
                + "画面上的手势是自绘的：双击暂停、横向拖进度、纵向拖音量。"
        case .ffmpeg:
            "自研 FFmpeg 的画面由我们自己解码、交给系统渲染管线（硬解走 VideoToolbox、软解走 libswscale，"
                + "都进 AVSampleBufferDisplayLayer）；解码方式严格按设置来，硬解不可用时播放页会提示改成软解。"
                + "音轨能在播放页换（从当前位置往后接，不回头对齐）；内嵌文本字幕能出字（样式不还原，M04P19）。"
        }
    }

    var body: some View {
        List {
            Section("当前形态") {
                InfoRow(title: "当前内核", value: model.preferredEngine.displayName)
                InfoRow(title: "控制方式", value: controlSummary)
                InfoRow(title: "倍速", value: "播放页「播放速度」区（0.1x–5.0x，含预设）")
                Text(controlDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("后续") {
                Text("自研 FFmpeg 内核的专属控制（逐帧步进、音频增益、渲染选项等）尚未做；"
                    + "上游的「长按屏幕临时加速」要接管手势、与既有手势冲突，暂不做（见 M02P15）。")
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
/// 结构对齐参考图的两行：`显示视图`（点开是「精简视图 / TMDB 视图」菜单）与
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

            // 切到 TMDB 视图才要求填（M11）：元信息那一层的三个入口。
            // 不填也能用 —— 只是那一层不工作、详情页显示占位，不弹错。
            if model.playbackPageLayout == .tmdb {
                TextField("TMDB api key", text: $model.tmdbConfig.apiKey)
                TextField("api 代理地址（可空）", text: $model.tmdbConfig.apiProxy)
                TextField("图片代理地址（可空）", text: $model.tmdbConfig.imageProxy)
                Text(model.isTMDBConfigured
                    ? "元信息已可用：标题、简介、图集都从 TMDB 取。"
                    : "没填 api key —— 元信息这一层不工作，界面显示占位。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 取图模式：顶部背景图现在就用它；选集卡片随后接同一套（PosterPicker 已共用）。
                Picker("海报方式", selection: $model.tmdbPosterMode) {
                    ForEach(PosterMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text("随机是**进页面定一次**，不是每张都在跳 —— 每张都换会像坏了。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 弹幕 API（解析器）

/// 弹幕显示：字号 / 透明度 / 速度 / 显示区域（M08i；控件在 M03P24 与播放页快捷面板共用）。
///
/// 四项都**即时生效**：改一次写一次 `UserDefaults`，播放页重排计划时读到 ——
/// 播放中把字号调大，下一帧就变大，不用退出重进。
///
/// 这一页现在只剩「说明 + 一组共用控件」（``DanmakuDisplayControls``）：播放页的「弹幕设置」
/// 快捷面板用的是同一组控件、同一份配置 —— 两个面一样，才不会有「设置页调的跟播放页调的不一样」。
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
            DanmakuDisplayControls(config: $model.danmakuDisplay)
        }
        .adaptiveListStyle()
        .navigationTitle("弹幕显示")
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
