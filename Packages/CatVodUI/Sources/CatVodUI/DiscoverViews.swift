import CatVodCore
import SwiftUI

// 发现页的界面件（对齐参考录屏）：分类条 / 筛选条 / 筛选胶囊 / 海报卡 / 站点切换面板。
//
// 这里只放「纯展示单元」：数据加载与状态在 `HomeView` / `HomeView+Data.swift`，
// 判定逻辑在 `DiscoverLayout.swift`，这样每个件都能在单测里直接构造。

/// 分类条：横向滚动的分类名，当前分类**加粗变黑**（参考视频没有胶囊底，靠字重区分）。
struct DiscoverCategoryStrip: View {
    let categories: [VodCategory]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(categories) { category in
                    Button {
                        onSelect(category.typeID)
                    } label: {
                        Text(category.typeName)
                            .fontWeight(category.typeID == selectedID ? .semibold : .regular)
                            .foregroundStyle(category.typeID == selectedID ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// 筛选区：一行一个筛选（左侧名可选）+ 右侧可横向滚动的胶囊。
struct DiscoverFilterStrip: View {
    let rows: [DiscoverFilterRow]
    let onSelect: (_ row: DiscoverFilterRow, _ value: String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    if row.showsName {
                        Text(row.name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(row.values) { value in
                                DiscoverFilterChip(
                                    title: value.chipTitle,
                                    isSelected: row.isSelected(value)
                                ) {
                                    onSelect(row, value.value)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// 筛选胶囊：选中是实心主题色 + 白字，未选中是淡灰底（参考视频的两种态）。
struct DiscoverFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 海报卡：封面 + 右上角角标 + 居中片名（参考视频的网格单元）。
struct DiscoverPosterCard: View {
    let item: VodItem

    /// 海报宽高比（参考视频里约 2:3）。
    static let aspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.secondary.opacity(0.12)
                    .aspectRatio(Self.aspectRatio, contentMode: .fit)
                    .overlay { poster }
                    .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))
                if !item.vodRemarks.isEmpty {
                    badge
                }
            }
            Text(item.vodName.isEmpty ? item.vodID : item.vodName)
                .font(.caption)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
    }

    /// 封面；加载中或失败时露出底下的淡灰占位（角标照常显示，与参考视频一致）。
    private var poster: some View {
        AsyncImage(url: URL(string: item.vodPic)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
    }

    /// 右上角角标：上游 `vodRemarks`（「更新至 58 集」「全 9 集」「HD」「4K」…）。
    private var badge: some View {
        Text(item.vodRemarks)
            .font(.caption2)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
            .padding(6)
    }
}

/// 站点切换面板：参考视频里点左上角站点名弹出，列出站点、当前项打勾。
struct DiscoverSitePanel: View {
    let sites: [Site]
    let selectedKey: String
    let onSelect: (String) -> Void

    /// 面板高度：参考图里约半屏，站点更多时在面板内部滚动。
    private static let height: CGFloat = 420

    var body: some View {
        List {
            Section("站点") {
                ForEach(sites) { site in
                    Button {
                        onSelect(site.key)
                    } label: {
                        HStack {
                            Text(site.name.isEmpty ? site.key : site.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if site.key == selectedKey {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .adaptiveListStyle()
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}
