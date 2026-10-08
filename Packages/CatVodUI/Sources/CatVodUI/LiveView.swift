import CatVodCore
import CatVodPlayer
import SwiftUI

// 直播页（M07c-2）：选源 → 选分组 → 频道 → 播放。
//
// 入口是**底部 Tab 的「直播」**（M07c-6 改）：此前挂在发现页工具栏的纸飞机按钮上 —— 那会儿按
// 参考录屏定的是「不加第 4 个 Tab」；用户后来指定改成 Tab，反转的理由与取舍见
// `docs/任务记录/M07c6-直播入口改底部Tab.md`。
//
// 版式沿用本 App 自己的习惯：分组条在顶部（与发现页的分类条同一形态），下面是频道列表；
// 每行给频道号、图标、名字和 EPG 的「正在播」。节目单分两条路：**文件形态**进页面拉一次全源，
// **接口形态**（x-tvg）按可见频道逐频道排队预取（见 `LiveEPGPrefetch`）。

/// 直播页。
@MainActor
public struct LiveView: View {
    @ObservedObject var model: AppModel

    /// 节目单页用 `sheet` 弹出：一个频道一档节目，弹层比 push 更贴上游的 `EpgDialog`，
    /// 也不会把导航栈堆成「列表 → 频道 → 节目单 → 播放」四层。
    /// 存**行**而不是频道：时移地址要按「这个频道上次用的线路」拼（M07c-3），`sheet` 里没得选线路。
    @State private var scheduleRow: LiveChannelRow?
    /// 直播设置（EPG 地址覆盖）的弹层。
    @State private var isEPGSettingPresented = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationTitle("直播")
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                // 直播设置（现在只有 EPG 地址覆盖；上游 `LiveEpgSetting` 也是挂在直播页的菜单里）。
                Button {
                    isEPGSettingPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("直播设置")
            }
            .sheet(isPresented: $isEPGSettingPresented) {
                AdaptiveNavigationContainer {
                    LiveEPGSettingView(model: model)
                }
            }
            .task {
                await model.loadLivePlaylist()
                // 文件形态的节目单（`epg` 里的 `.xml` / `.gz`）：清单到手后拉一次，一份覆盖多频道
                // （上游 `LiveActivity.onLiveParsed` → `LiveApi.parseXml`）。
                // 接口形态（x-tvg）是逐频道的，由每行的 `.task` 排队预取（见 `LiveEPGPrefetch`）。
                await model.loadLiveFileGuide()
            }
            .onChange(of: model.siteCatalogRevision) { _ in
                // 接口换了：直播页现在是底部 Tab 的**常驻**视图，`.task` 在回到该 Tab 时不一定重跑
                // （与首页 M02P9 同一类问题）—— 不自己重载就会一直显示上一个接口的频道。
                // 用非结构化 `Task`：离开这个 Tab 时这次重载不该被取消。
                Task {
                    await model.loadLivePlaylist(force: true)
                    await model.loadLiveFileGuide(force: true)
                }
            }
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
            if let target = model.liveResumeTarget {
                resumeRow(target)
                Divider()
            }
            if !model.liveEPGNotice.isEmpty {
                // 节目单拿不到的原因 / 预取到顶的说明：不弹错，但必须能看见 ——
                // 否则「为什么整页都是『暂无节目』」永远查不出来。
                Text(model.liveEPGNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                Divider()
            }
            channelList
        }
    }

    /// 「继续观看」：**不自动开播**（进页面就出声是打扰），把上次看的频道摆在列表上方，
    /// 一点就到、并且仍然用上次那条线路（线路名来自清单里的 `地址$线路名`）。
    private func resumeRow(_ target: LiveKeepTarget) -> some View {
        NavigationLink {
            LiveChannelPlaybackView(model: model, channel: target.channel, lineIndex: target.lineIndex)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("继续观看")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(target.channel.name) · \(LiveListLayout.lineTitle(channel: target.channel, lineIndex: target.lineIndex))")
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 分组条：当前分组加粗（与发现页分类条同一形态；加密分组带一个锁、「收藏」带一个星）。
    private func groupStrip(_ source: LiveSource) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(LiveListLayout.groupRows(source, favoriteCount: favoriteCount)) { row in
                    let isSelected = row.name == model.selectedLiveGroupObject?.name
                    Button {
                        model.selectedLiveGroup = row.name
                    } label: {
                        HStack(spacing: 4) {
                            if row.isKeep {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                            }
                            if row.isHidden {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                            }
                            // 字重加在 `Text` 上（iOS 13+）：`.fontWeight` 这个 **View 修饰符**要 iOS 16+，
                            // 是「iOS 15 下限」踩过的一个坑（与发现页分类条同一写法）。
                            Text(row.name)
                                .font(isSelected ? .body.weight(.semibold) : .body)
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// 收藏的频道数（分组条据此决定要不要给「收藏」这一组）。
    private var favoriteCount: Int {
        model.liveFavoriteGroup?.channels.count ?? 0
    }

    private var channelList: some View {
        List {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    NavigationLink {
                        LiveChannelPlaybackView(model: model, channel: row.channel, lineIndex: row.initialLineIndex)
                    } label: {
                        LiveChannelRowView(row: row, isFavorite: model.isLiveFavorite(row.channel))
                    }
                    // 节目单入口：一个频道的各档节目（时移回看从这里进）。
                    Button {
                        scheduleRow = row
                    } label: {
                        Image(systemName: "calendar")
                            .font(.body)
                            .accessibilityLabel("节目单")
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.isPlayable)
                }
                // 「可见即预取」：这一行真的被渲染出来了，才为它排队拉节目单
                // （串行 + 去重 + 失败不重试 + 本次进入封顶，见 `LiveEPGPrefetch`）。
                .task { model.requestLiveGuide(for: row.channel) }
                // 收藏：长按（iOS）/ 右键（macOS）—— 上游 `LiveActivity.onLongClick` 就是这个触发方式。
                // 加密分组里的频道不给收藏（上游 `if (mGroup.isHidden()) return false;`，在模型里拦）。
                .contextMenu {
                    Button {
                        model.toggleLiveFavorite(row.channel)
                    } label: {
                        Text(model.isLiveFavorite(row.channel) ? "取消收藏" : "收藏")
                    }
                }
            }
        }
        .adaptiveListStyle()
        .sheet(item: $scheduleRow) { row in
            AdaptiveNavigationContainer {
                LiveScheduleView(model: model, channel: row.channel, lineIndex: row.initialLineIndex)
            }
        }
    }

    /// 当前分组的频道行：节目单按**频道各自**取（缓存就在 ``AppModel/liveGuides`` 里），
    /// 「上次观看」也按行标出来（`resume` 传一次，别在每行里各解析一遍）。
    private var rows: [LiveChannelRow] {
        guard let group = model.selectedLiveGroupObject else {
            return []
        }
        let now = Date()
        let resume = model.liveResumeTarget
        return group.channels.map { channel in
            LiveListLayout.row(channel, guide: model.liveGuide(for: channel), resume: resume, at: now)
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

/// 频道列表的一行：图标 + 名字 + 「正在播」，右侧给「上次」/ 收藏星标 / 回看标记与频道号。
private struct LiveChannelRowView: View {
    let row: LiveChannelRow
    /// 已收藏时给一个小星标（收藏本身是长按 / 右键切换，星标只是状态回显）。
    let isFavorite: Bool

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

            if row.isLastWatched {
                Text("上次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.hasCatchup {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("可回看")
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已收藏")
            }
            Text(row.number)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// 频道的播放页。
///
/// 三件事：
/// - 进入时顺手拉这个频道的节目单（回到列表就有「正在播」）；
/// - 把这次观看记成「上次观看」（`分组名@@@频道名@@@线路下标`，上游 `Live.keep` 的形态）；
/// - 一个频道有多条线路时，右上角给线路菜单（清单写了 `地址$线路名` 就用线路名）。
///
/// `lineIndex` 由调用方给（上次看的那条），在这里只往上改、不再往下改：换线路同样要写「上次观看」。
///
/// 资源交给 ``AppModel/proxiedMediaResource(_:)``：需要 header 时改走本机 `/proxy`，
/// 让 header 覆盖到子清单 / 分片 / 密钥请求上（M6 的约定）。
@MainActor
private struct LiveChannelPlaybackView: View {
    @ObservedObject var model: AppModel
    let channel: LiveChannel
    @State private var lineIndex: Int

    init(model: AppModel, channel: LiveChannel, lineIndex: Int) {
        self.model = model
        self.channel = channel
        _lineIndex = State(initialValue: lineIndex)
    }

    var body: some View {
        PlaybackView(resource: resource, title: title, settings: model.playbackSettings)
            // 换线路 = 换资源：`PlaybackView` 自己的 `.task` 只在视图出现时跑一次，所以用 `id`
            // 让播放页重建（不重建就会继续播旧线路）。
            .id(lineIndex)
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                if channel.urls.count > 1 {
                    lineMenu
                }
            }
            .task {
                await model.loadLiveGuide(for: channel)
                model.rememberLiveChannel(channel, lineIndex: lineIndex)
            }
    }

    // MARK: - 线路

    /// 线路菜单：当前线路带对勾；没写线路名的线路按「线路 N」。
    private var lineMenu: some View {
        Menu {
            ForEach(Array(channel.urls.indices), id: \.self) { index in
                Button {
                    selectLine(index)
                } label: {
                    if index == lineIndex {
                        Label(LiveListLayout.lineTitle(channel: channel, lineIndex: index), systemImage: "checkmark")
                    } else {
                        Text(LiveListLayout.lineTitle(channel: channel, lineIndex: index))
                    }
                }
            }
        } label: {
            Text(LiveListLayout.lineTitle(channel: channel, lineIndex: lineIndex))
        }
    }

    /// 换线路：先记住这次选择（`id` 重建会重放 `.task`，但不能指望它 —— 换线路只是换个
    /// 子视图的身份，外层的 `.task` 不一定重跑），再切地址让播放页重建。
    private func selectLine(_ index: Int) {
        guard index != lineIndex else {
            return
        }
        lineIndex = index
        model.rememberLiveChannel(channel, lineIndex: index)
    }

    // MARK: - 播放

    /// 标题：EPG 的 `<display-name>` 优先，否则清单里的频道名（与列表同一口径）。
    private var title: String {
        model.liveGuide(for: channel)?.displayName(for: channel.epgID, fallback: channel.name) ?? channel.name
    }

    private var resource: MediaResource {
        model.proxiedMediaResource(MediaResource(
            url: channel.playbackURL(index: lineIndex),
            headers: channel.requestHeaders(fallback: model.liveSource?.headers() ?? [:])
        ))
    }
}
