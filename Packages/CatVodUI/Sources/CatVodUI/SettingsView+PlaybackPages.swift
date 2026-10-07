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

/// 播放器：内核与解码方式。
///
/// 与「源地址 → 接口管理」里的「播放设置」区块共用 ``PlaybackSettingsSection``。
@MainActor
struct SettingsPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackSettingsSection(model: model)
        }
        .adaptiveListStyle()
        .navigationTitle("播放器")
    }
}

// MARK: - 播放页

/// 播放页：外观与手势的现状说明。
///
/// 现在的播放页是系统原生 `AVKit.VideoPlayer`（`docs/UI 规范.md`：不自绘播放控件），
/// 因此**没有可配置项**；M3（MPVKit）/ M4（自研 FFmpeg）接入 `PlayerCoordinator` 之后
/// 才会出现内核专属设置（渲染方式、音视频轨道、字幕/弹幕渲染等）。
/// 这里如实说明现状，而不是给一个假开关。
@MainActor
struct SettingsPlaybackPageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section("当前形态") {
                InfoRow(title: "播放页", value: "系统原生（AVKit）")
                InfoRow(title: "当前内核", value: model.preferredEngine.displayName)
                Text("播放页的控件、手势与画中画都由系统播放器提供，本项目不自绘 —— 所以现在没有可调的播放页设置项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("后续") {
                Text("M3（MPVKit）/ M4（自研 FFmpeg）接入后，这里会出现内核专属设置：渲染方式、音视频轨道选择、字幕与弹幕渲染开关等。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放页")
    }
}

// MARK: - 弹幕 API（解析器）

/// 弹幕 API：列出当前接口配置里的解析器（`parses`）。
///
/// 对照 `docs/协议兼容矩阵.md`：解析链（`parse`/`jx`）与 Web 嗅探在 M5，弹幕/字幕渲染在 M8。
/// 这里先把**配置里真实存在的解析器**列出来（名称、类型、可用性与原因），
/// 让用户能判断「这个源有没有解析/弹幕能力」，而不是只看到一片空白。
@MainActor
struct SettingsDanmakuAPIView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            if parsers.isEmpty {
                Section("弹幕 API") {
                    Text(emptyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("解析器（parses）") {
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
