import CatVodCore
import SwiftUI

/// 播放页的「选择弹幕」面板（M03P25，对齐上游 `DanmakuDialog` + `DanmakuSearchDialog`）。
///
/// 三块：状态一行、候选列表（第一条是「自动」）、换关键词重搜。
/// 与「弹幕设置」（``PlaybackDanmakuSettings``）同一形态：半屏 sheet —— 上游这两张也都是 bottom sheet。
///
/// 纯展示 + 三个回调（`switcher` 里那对 `select` / `search`）：面板不认识 `AppModel`，
/// 候选与动作都由播放页从宿主那儿递进来（见 ``PlaybackDanmakuSwitcher``）。
struct PlaybackDanmakuPicker: View {
    let switcher: PlaybackDanmakuSwitcher
    /// 这一集原本搜的是什么（预填搜索框）；`nil` = 没得可搜（那就不摆搜索区）。
    let request: DanmakuRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var episode = ""
    @State private var isSearching = false
    /// 上一次重搜的失败原因；空串 = 没失败（面板自己的一行，不碰正在播的那份状态）。
    @State private var searchNote = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if !switcher.status.isEmpty {
                    Section {
                        Text(switcher.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    row(title: "自动", detail: "站点自带的优先，其次搜索到的第一条", isSelected: switcher.selected == nil) {
                        Task { await switcher.select(nil) }
                    }
                    ForEach(switcher.candidates) { source in
                        row(title: source.displayName, detail: source.source, isSelected: source == switcher.selected) {
                            Task { await switcher.select(source) }
                        }
                    }
                } header: {
                    Text("候选（\(switcher.candidates.count) 条）")
                } footer: {
                    Text("点一条就当场换过来。文件名对不上 / 文件是空的就换一条，或回到自动。")
                }
                if request != nil {
                    searchSection
                }
            }
            .adaptiveListStyle()
        }
        .onAppear {
            // 预填这一集原本的片名 / 集名（用户可以改 —— 上游那个搜索框也是可改的）。
            name = request?.name ?? ""
            episode = request?.episode ?? ""
        }
    }

    /// 面板头：标题 + 完成（与「弹幕设置」面板同一形态）。
    private var header: some View {
        HStack {
            Text("选择弹幕")
                .font(.headline)
            Spacer()
            Button("完成") {
                dismiss()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 换关键词重搜：只换上面的候选列表，不动正在播的那份（选哪条由用户点）。
    private var searchSection: some View {
        Section {
            TextField("片名", text: $name)
            TextField("集名", text: $episode)
            Button {
                Task { await runSearch() }
            } label: {
                HStack(spacing: 6) {
                    if isSearching {
                        ProgressView()
                    }
                    Text(isSearching ? "搜索中…" : "搜索")
                }
            }
            .disabled(isSearching)
            if !searchNote.isEmpty {
                Text(searchNote)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("重新搜索")
        } footer: {
            Text("搜出来的接进上面的候选。名字对不上时改一下再搜（比如去掉「第 x 季」）。")
        }
    }

    /// 一行候选：名字 + 来源 + 选中的勾。
    ///
    /// 行是 `Button` 但走 `.plain` 样式：默认样式会把没显式定色的文字全刷成 tint 蓝
    /// （选集抽屉踩过一次），这里的颜色配比是刻意的。
    private func row(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(isSelected ? PlatformShims.accent : Color.primary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PlatformShims.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func runSearch() async {
        isSearching = true
        searchNote = ""
        searchNote = await switcher.search(name, episode) ?? ""
        isSearching = false
    }
}
