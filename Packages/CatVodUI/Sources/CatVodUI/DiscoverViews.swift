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
    /// 抽标签 / 显示名 / 搜索的**全部输入**（接口规则 + 自建规则 + 关掉的 id + 自定义名）。
    var ruleInput = DiscoverSiteRuleInput()
    /// 存下来的分组顺序（空 = 用「按站点顺序首次出现」的默认顺序）。
    var savedGroupOrder: [String] = []
    /// 分组顺序变了（长按菜单里的上移/下移）：回传分组名与方向，由上层算新顺序并落盘。
    var onMoveGroup: ((String, Int) -> Void)?
    /// 站点改名（回传站点 key 与新名字；新名字为空 = 恢复原名）。
    var onRename: ((String, String) -> Void)?
    let onSelect: (String) -> Void

    /// 当前选中的分组（空 = 不筛）。面板每次打开重置 —— 与上游「关掉就忘」一致。
    @State private var selectedGroup = ""
    /// 搜索关键词（同样只在这次展示内有效）。
    @State private var keyword = ""
    /// 每个站点抽出来的标签。在这里缓存一次：抽标签要跑正则，不该每次渲染都重算。
    /// 分组顺序与筛选都是基于它的**廉价**计算，所以「上移/下移之后立刻看到新顺序」不用重新抽标签；
    /// 改名、开关规则、加自建规则 —— 任一项变了都要重抽，所以 `.task(id: ruleInput)` 盯的是整个输入。
    @State private var tags: [String: [String]] = [:]
    /// 重命名弹窗的状态（站点 key 与输入框内容）。
    @State private var renameKey = ""
    @State private var renameText = ""
    @State private var isRenamePresented = false

    /// 面板宽度占屏宽的比例：录屏里约占 2/3。
    static let widthFraction: CGFloat = 0.66
    /// 面板高度占可用高度的比例：录屏里从工具栏下方一直伸到接近屏幕底部。
    static let heightFraction: CGFloat = 0.78
    /// 单行高度。
    static let rowHeight: CGFloat = 44
    /// 面板圆角。
    static let cornerRadius: CGFloat = 12

    private var groups: [String] {
        DiscoverSiteList.groups(sites: sites, tags: tags, savedOrder: savedGroupOrder)
    }

    private var rows: [DiscoverSiteRow] {
        DiscoverSiteList.rows(
            sites: sites,
            selectedKey: selectedKey,
            names: ruleInput.names,
            tags: tags,
            selectedGroup: selectedGroup,
            keyword: keyword
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            groupBar
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
                        .contextMenu {
                            Button("重命名") { beginRename(row) }
                            if hasCustomName(row.key) {
                                Button("恢复原名", role: .destructive) { onRename?(row.key, "") }
                            }
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(radius: 14, y: 6)
        .task(id: ruleInput) {
            tags = DiscoverSiteList.tags(sites: sites, input: ruleInput)
        }
        .alert("重命名站点", isPresented: $isRenamePresented) {
            TextField("显示名", text: $renameText)
            Button("保存") { onRename?(renameKey, renameText) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("填成原名（或清空）即为恢复；分组标签按新名字重抽。")
        }
    }

    /// 搜索框：**按生效名 / 原名 / 站点 key** 命中（规则在 `SiteNameRules`）。
    ///
    /// 上游把搜索放在同一个面板里，这里保持一致：面板本来就是「找站点」的地方，
    /// 再开一层弹窗只会多一次跳转。
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索站点", text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func hasCustomName(_ key: String) -> Bool {
        !(ruleInput.names[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 打开重命名弹窗：输入框预填**当前生效名**（上游 `getEditableName` 同款）。
    private func beginRename(_ row: DiscoverSiteRow) {
        renameKey = row.key
        renameText = hasCustomName(row.key) ? (ruleInput.names[row.key] ?? row.title) : row.title
        isRenamePresented = true
    }

    /// 分组条：**有分组才显示**（对齐上游：`groups.isEmpty()` 时整条隐藏）。
    @ViewBuilder
    private var groupBar: some View {
        let values = groups
        if !values.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(values, id: \.self) { group in
                        groupChip(group)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()
        }
    }

    /// 一个分组胶囊：点一下筛选、再点一下取消（上游同款交互，没有额外的「全部」项）。
    ///
    /// 上游是**长按拖动**排序；iOS 上横向滚动手势会和拖动排序打架，这里改成
    /// 长按弹出「上移 / 下移」菜单 —— 结果一样，少一个手势（差异记在 M06d 文档里）。
    private func groupChip(_ group: String) -> some View {
        let active = group == selectedGroup
        return Button {
            selectedGroup = active ? "" : group
        } label: {
            Text(group)
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("上移") { onMoveGroup?(group, -1) }
            Button("下移") { onMoveGroup?(group, 1) }
        }
        .accessibilityLabel("分组 \(group)")
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
