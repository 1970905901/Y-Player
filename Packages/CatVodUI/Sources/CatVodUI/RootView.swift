import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 应用根视图（占位壳）。
///
/// 当前只展示工程状态与协议能力的自检信息；M2 会替换为「接口管理 → 首页 → 分类 → 详情 → 播放」的完整链路。
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationView {
            List {
                Section(header: Text("工程状态")) {
                    Label("协议核心（CatVodCore）已就绪", systemImage: "checkmark.seal")
                    Label(engineStatusText, systemImage: "play.rectangle")
                    Text("js2p 主接口：需随包内嵌 Node 运行时（见 docs/js2p宿主契约.md）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("下一步")) {
                    Text("M1.6：在 macOS/真机上验证内嵌 Node 启动与 /spider 路由")
                    Text("M2：接入接口管理、站点列表、搜索、详情与播放")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("YPlayer")
        }
        .navigationViewStyle(.stack)
    }

    /// 播放内核可用性（M3 启用 MPVKit 前，两者均不可用，UI 必须如实展示）。
    private var engineStatusText: String {
        let mpv = PlayerEngineKind.mpv.isAvailable ? "可用" : "未启用"
        let ffmpeg = PlayerEngineKind.ffmpeg.isAvailable ? "可用" : "未启用"
        return "播放内核：MPV \(mpv) / 自研 FFmpeg \(ffmpeg)"
    }
}
