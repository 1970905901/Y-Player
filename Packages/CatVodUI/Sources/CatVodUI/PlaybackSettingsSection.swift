import CatVodPlayer
import SwiftUI

/// 播放设置区块：播放内核 + 解码方式 + 可用性说明。
///
/// 两个入口共用同一份实现（避免两处各写一份内核 Picker，出现「两个页面显示的内核不一样」）：
/// - 设置 → 播放 → 播放器（``SettingsPlayerView``）；
/// - 设置 → 源地址 → 接口管理页里的「播放设置」区块（``InterfaceManagementView``）。
///
/// 语义仍是 M2 定下的：**用户手动选择、不自动降级**；选了不可用的内核就如实说明原因。
struct PlaybackSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let resolution = model.resolvePlayback()
        Section("播放设置") {
            Picker("播放内核", selection: $model.preferredEngine) {
                ForEach(PlayerEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName + (kind.isAvailable ? "" : "（未接入）")).tag(kind)
                }
            }
            Picker("解码方式", selection: $model.decoderMode) {
                ForEach(DecoderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Toggle("本地代理注入 header", isOn: $model.isLocalProxyEnabled)
            Text(
                "开启后，需要 header 的播放地址会改走本机服务（127.0.0.1），"
                    + "由它把 Referer/UA/Cookie 注入到主清单、子清单、分片与密钥请求上——"
                    + "系统播放器本身只能给主请求设 header。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if !model.localProxyNotice.isEmpty {
                InfoRow(title: "本机服务", value: model.localProxyNotice)
            }
            switch resolution {
            case let .ready(kind):
                InfoRow(title: "将使用", value: kind.displayName)
            case let .unavailable(kind, reason):
                InfoRow(title: "不可用", value: kind.displayName)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !model.playbackSettings.isDecoderModeEffective {
                Text("提示：系统播放器不支持强制硬解/软解，该选项对当前内核无效（切到 MPV / 自研 FFmpeg 内核后生效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.playbackNotice.isEmpty {
                Text(model.playbackNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.adSkipNotice.isEmpty {
                Label(model.adSkipNotice, systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
