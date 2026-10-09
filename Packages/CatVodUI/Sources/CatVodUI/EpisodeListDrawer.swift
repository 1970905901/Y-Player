import CatVodCore
import SwiftUI

/// 剧集列表抽屉（M11 · 选集区头「更多」的落点，参考视频 f07/f08/f12）：
/// 整屏文件列表、当前集高亮、右上「正序 / 倒序」、可滚动 —— 以 sheet 叠加在详情页上。
///
/// 刻意保持「纯展示 + 一个回调」：数据与跳转都在 `VodDetailView` —— 点一集回传下标，
/// 由那边关抽屉并走**与点卡片同一条**的隐藏导航链进播放页（不另开一条跳转路径）。
struct EpisodeListDrawer: View {
    let episodes: [PlaylistParser.Episode]
    /// 当前集下标（「继续播放 / 上次看到」那一集）；nil = 不高亮。
    let currentIndex: Int?
    /// 点一集：回传下标，由调用方负责关抽屉与跳转。
    let onSelect: (Int) -> Void

    /// 正序 / 倒序：只影响抽屉里的显示顺序，不动数据。
    @State private var descending = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(orderedIndices, id: \.self) { index in
                    row(at: index)
                }
            }
            .listStyle(.plain)
        }
    }

    private var orderedIndices: [Int] {
        let indices = Array(episodes.indices)
        return descending ? Array(indices.reversed()) : indices
    }

    /// 抽屉头：标题 + 右上「正序 / 倒序」（按钮显示的是**当前**顺序，点一下翻转）。
    private var header: some View {
        HStack {
            Text("剧集列表")
                .font(.headline)
            Spacer()
            Button {
                descending.toggle()
            } label: {
                Label(descending ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 一行：序号 + 文件名（空名回落「第 N 集」）+ 当前集高亮与对勾。
    ///
    /// 行是 `Button` 但走 `.plain` 样式：默认样式会把没显式定色的文字全刷成 tint 蓝
    /// （播放器设置页刚栽过一次），这里的颜色配比是刻意的。
    private func row(at index: Int) -> some View {
        Button {
            onSelect(index)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(episodes[index].name.isEmpty ? "第 \(index + 1) 集" : episodes[index].name)
                    .font(.footnote)
                    .foregroundStyle(index == currentIndex ? PlatformShims.accent : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if index == currentIndex {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PlatformShims.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
