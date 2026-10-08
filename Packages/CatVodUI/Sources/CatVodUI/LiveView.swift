import CatVodCore
import CatVodPlayer
import SwiftUI

// 直播页（M07c-2）：选源 → 选分组 → 频道 → 播放。
//
// 入口是发现页工具栏的**纸飞机**按钮：参考录屏的三个 Tab（发现 / 追剧 / 设置）里没有直播 Tab，
// 上游手机版也是 `LiveActivity.start(this)` 这种 push 形态，所以这里不开第 4 个 Tab。
//
// 版式沿用本 App 自己的习惯：分组条在顶部（与发现页的分类条同一形态），下面是频道列表；
// 每行给频道号、图标、名字和 EPG 的「正在播」。节目单按上游语义**逐频道拉**
// （拉的是这个频道「昨天 / 今天 / 明天」三天），不走「一次拉全源」——那是文件形态才有的做法。

/// 直播页。
@MainActor
public struct LiveView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationTitle("直播")
            .task { await model.loadLivePlaylist() }
    }

    // MARK: - 分支

    @ViewBuilder private var content: some View {
        if model.liveSources.isEmpty {
            placeholder("当前接口里没有直播源。\n可在「设置 → 源地址」里换一个带 `lives` 的配置。")
        } else if model.liveState.isLoading {
            ProgressView("正在加载直播清单…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reason = model.liveState.failureReason {
            placeholder(reason)
        } else if let source = model.liveSource {
            playlist(source)
        } else {
            placeholder("正在准备…")
        }
    }

    private func playlist(_ source: LiveSource) -> some View {
        VStack(spacing: 0) {
            groupStrip(source)
            Divider()
            channelList
        }
    }

    /// 分组条：当前分组加粗（与发现页分类条同一形态；加密分组带一个锁）。
    private func groupStrip(_ source: LiveSource) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(LiveListLayout.groupRows(source)) { row in
                    Button {
                        model.selectedLiveGroup = row.name
                    } label: {
                        HStack(spacing: 4) {
                            if row.isHidden {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                            }
                            Text(row.name)
                        }
                        .fontWeight(row.name == model.selectedLiveGroupObject?.name ? .semibold : .regular)
                        .foregroundStyle(row.name == model.selectedLiveGroupObject?.name ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var channelList: some View {
        List {
            ForEach(rows) { row in
                NavigationLink {
                    LiveChannelPlaybackView(model: model, row: row)
                } label: {
                    LiveChannelRowView(row: row)
                }
            }
        }
        .adaptiveListStyle()
    }

    /// 当前分组的频道行：节目单按**频道各自**取（缓存就在 ``AppModel/liveGuides`` 里）。
    private var rows: [LiveChannelRow] {
        guard let group = model.selectedLiveGroupObject else {
            return []
        }
        let now = Date()
        return group.channels.map { channel in
            LiveListLayout.row(channel, guide: model.liveGuide(for: channel), at: now)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新加载") {
                Task { await model.loadLivePlaylist(force: true) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 频道列表的一行：图标 + 名字 + 「正在播」，右侧给回看标记与频道号。
private struct LiveChannelRowView: View {
    let row: LiveChannelRow

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: row.logo)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.secondary.opacity(0.12)
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                Text(row.currentText.isEmpty ? "暂无节目" : row.currentText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if row.hasCatchup {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("可回看")
            }
            Text(row.number)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// 频道的播放页。
///
/// 进入时顺手拉这个频道的节目单（回到列表就有「正在播」），资源交给
/// ``AppModel/proxiedMediaResource(_:)``：需要 header 时改走本机 `/proxy`，
/// 让 header 覆盖到子清单 / 分片 / 密钥请求上（M6 的约定）。
private struct LiveChannelPlaybackView: View {
    @ObservedObject var model: AppModel
    let row: LiveChannelRow

    var body: some View {
        PlaybackView(resource: resource, title: row.title, settings: model.playbackSettings)
            .task { await model.loadLiveGuide(for: row.channel) }
    }

    private var resource: MediaResource {
        model.proxiedMediaResource(MediaResource(
            url: row.channel.playbackURL(),
            headers: row.channel.requestHeaders(fallback: model.liveSource?.headers() ?? [:])
        ))
    }
}
