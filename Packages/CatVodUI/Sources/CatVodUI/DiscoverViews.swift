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

/// 左上角「站点切换」图标：参考录屏里是两个开关（上一个空、下一个满）。
///
/// 为什么自己画而不用 SF Symbol：录屏里这个字形在 SF Symbols 里没有对应项，
/// 而它是「点这里切换站点」的唯一提示，画错或画丢都会让人找不到切换入口。
/// （⚠️ 站点名里那个「☁️」不是按钮图标，它是上游给的**站点名自带**的表情。）
struct DiscoverSiteSwitchGlyph: View {
    /// 图标宽度；高度按两个开关的比例自动算。
    var size: CGFloat = 17

    var body: some View {
        VStack(spacing: size * 0.16) {
            Capsule()
                .strokeBorder(Color.accentColor, lineWidth: max(size * 0.11, 1))
                .frame(width: size, height: size * 0.42)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .padding(.leading, size * 0.09)
                }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: size, height: size * 0.42)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .padding(.trailing, size * 0.09)
                }
        }
        .accessibilityLabel("站点切换")
    }
}

/// 站点切换面板：参考录屏里点左上角「切换」图标弹出。
///
/// 版式按录屏对齐：**贴着左边的悬浮卡片**（不是居中弹窗，面板外也没有变暗层），
/// 每行一个站点名、当前站点右侧打勾，行与行之间一条细线；站点多时面板内部滚动。
/// 站点名原样显示 —— 上游给的就是 `名称|标记` 这种整串名字，不做二次改写。
struct DiscoverSitePanel: View {
    let sites: [Site]
    let selectedKey: String
    let onSelect: (String) -> Void

    /// 面板宽度占屏宽的比例：录屏里约占 2/3。
    static let widthFraction: CGFloat = 0.66
    /// 面板高度占可用高度的比例：录屏里从工具栏下方一直伸到接近屏幕底部。
    static let heightFraction: CGFloat = 0.78
    /// 单行高度。
    static let rowHeight: CGFloat = 44
    /// 面板圆角。
    static let cornerRadius: CGFloat = 12

    private var rows: [DiscoverSiteRow] {
        DiscoverSiteList.rows(sites: sites, selectedKey: selectedKey)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    Button {
                        onSelect(row.key)
                    } label: {
                        label(row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(radius: 14, y: 6)
    }

    private func label(_ row: DiscoverSiteRow) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if row.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}
