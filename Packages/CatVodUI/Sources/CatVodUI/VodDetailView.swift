import CatVodCore
import CatVodSource
import SwiftUI

/// 详情页：影片信息 → 线路 → 选集 → 播放。
///
/// 播放能力边界（M2）：
/// - 直链且无需解析的集（`parse = 0`）可直接用系统播放器播放；
/// - 需要解析的集（`parse/jx = 1`）依赖 M5 的解析链；
/// - `type=3` 的 JS / CatSpider 站点依赖 M1.6 的内嵌 Node 服务。
/// 以上情况都会进入 ``UnsupportedPlaybackView`` 并说明原因，不静默失败。
@MainActor
public struct VodDetailView: View {
    @ObservedObject var model: AppModel
    let site: Site?
    let vodID: String

    @State var detail = SpiderResult()
    @State var lines: [PlaylistParser.Line] = []
    @State var selectedLineIndex = 0
    @State var isLoading = false
    @State var errorText = ""

    public init(model: AppModel, site: Site?, vodID: String) {
        self.model = model
        self.site = site
        self.vodID = vodID
    }

    var vod: VodItem? {
        detail.list.first
    }

    var currentLine: PlaylistParser.Line? {
        guard lines.indices.contains(selectedLineIndex) else {
            return lines.first
        }
        return lines[selectedLineIndex]
    }

    public var body: some View {
        List {
            headerSection
            if lines.count > 1 {
                lineSection
            }
            episodesSection
            if !errorText.isEmpty {
                Section("错误") {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "详情") : "详情")
        .refreshable { await loadDetail(force: true) }
        .task { await loadDetail() }
    }

    // MARK: - 区块

    private var headerSection: some View {
        Section("影片") {
            if isLoading, detail.list.isEmpty {
                Text("加载中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let vod {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: URL(string: vod.vodPic)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                    .frame(width: 80, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(vod.vodName.isEmpty ? vod.vodID : vod.vodName)
                            .font(.headline)
                        if !vod.vodRemarks.isEmpty {
                            Text(vod.vodRemarks)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !vod.typeName.isEmpty {
                            Text(vod.typeName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !vod.vodYear.isEmpty || !vod.vodArea.isEmpty {
                            Text([vod.vodYear, vod.vodArea].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !vod.vodActor.isEmpty {
                    Text("演员：\(vod.vodActor)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !vod.vodDirector.isEmpty {
                    Text("导演：\(vod.vodDirector)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !vod.vodContent.isEmpty {
                    Text(vod.vodContent)
                        .font(.footnote)
                }
            }
        }
    }

    private var lineSection: some View {
        Section("线路") {
            Picker("线路", selection: $selectedLineIndex) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.name).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var episodesSection: some View {
        Section("选集") {
            if lines.isEmpty {
                Text(isLoading ? "加载中…" : "没有可用线路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(currentLine?.episodes ?? []) { episode in
                NavigationLink {
                    destination(for: episode)
                } label: {
                    HStack {
                        Text(episode.name.isEmpty ? "播放" : episode.name)
                        Spacer()
                        if makeResource(for: episode) == nil {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for episode: PlaylistParser.Episode) -> some View {
        if let resource = makeResource(for: episode) {
            PlaybackView(
                resource: resource,
                title: episode.displayName,
                settings: model.playbackSettings
            )
        } else {
            UnsupportedPlaybackView(reason: unsupportedReason(for: episode))
        }
    }
}
