import CatVodCore
import CatVodStore
import SwiftUI

/// 「追剧」页的范围：播放历史 / 收藏记录（对齐参考图顶部的下拉）。
enum LibraryScope: String, CaseIterable, Sendable, Hashable {
    case history
    case favorites

    var displayName: String {
        switch self {
        case .history: "播放历史"
        case .favorites: "收藏记录"
        }
    }

    /// 菜单图标（与参考图一致：历史是时钟、收藏是星标）。
    var icon: String {
        switch self {
        case .history: "clock"
        case .favorites: "star"
        }
    }
}

/// 「追剧」页：播放历史与收藏记录（参考图 2、3 的「追剧」Tab）。
///
/// 数据来源都**不发网络请求**：
/// - 播放历史 → `AppModel.progressStore`（播放页边播边记：进度 + 片名/封面/站源/线路/集名）；
/// - 收藏记录 → `AppModel.favoriteStore`（详情页「收藏」写入）。
///
/// 落库（GRDB）在 M8：现在是内存实现，**杀进程即丢** —— 空态里必须对用户明说，
/// 否则会被当成「历史功能坏了」。
///
/// 行点击可进详情，但只有当该站点**仍在当前接口里**时才可进入（换源后旧站点会消失）；
/// 进不去时行内直接给出原因，而不是点了没反应。
@MainActor
public struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State var scope: LibraryScope = .history
    @State var records: [PlaybackProgress] = []
    @State var favorites: [Favorite] = []
    /// 是否处于多选态。
    ///
    /// 刻意**不用** SwiftUI 的 `EditMode`：它是 iOS/tvOS 专有（macOS 上 `EditMode` / `\.editMode`
    /// 直接不可用），而本项目要求「业务视图不写平台分支」（见 `docs/UI 规范.md`）。
    /// 这里用自有状态 + 行内勾选标记 + 工具栏删除，两端行为一致。
    @State var isSelecting = false
    @State var selection = Set<String>()

    /// 本 Tab 的沉浸页登记簿（详情 / 播放压上来时收起底部 Tab 栏）。
    @EnvironmentObject private var immersiveTabBar: ImmersiveTabBarState

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            switch scope {
            case .history:
                historySection
            case .favorites:
                favoritesSection
            }
        }
        .adaptiveListStyle()
        .navigationTitle(scope.displayName)
        .adaptiveTabBarHidden(immersiveTabBar.isActive)
        .adaptiveToolbar {
            scopeMenu
        } trailing: {
            HStack(spacing: 16) {
                if isSelecting, !selection.isEmpty {
                    Button("删除", role: .destructive) {
                        Task { await deleteSelected() }
                    }
                }
                selectButton
            }
        }
        .task {
            await reload()
        }
        .onChange(of: scope) { _ in
            // 切范围时退出多选并清空选择：选中的是「另一个列表」的行，留着会误删。
            isSelecting = false
            selection = []
        }
        .onChange(of: model.siteCatalogRevision) { _ in
            // 接口换了：站点可能已不存在，行内「能否进详情」的提示要跟着更新。
            // 记录本身不动 —— 它们属于用户，不属于接口。
            Task { await reload() }
        }
    }

    // MARK: - 区块

    private var historySection: some View {
        Section {
            if records.isEmpty {
                Text(historyEmptyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(records, id: \.key.storageKey) { record in
                historyRow(record)
            }
            .onDelete { offsets in
                Task { await deleteHistory(at: offsets) }
            }
        }
    }

    private var favoritesSection: some View {
        Section {
            if favorites.isEmpty {
                Text(favoritesEmptyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites) { favorite in
                favoriteRow(favorite)
            }
            .onDelete { offsets in
                Task { await deleteFavorites(at: offsets) }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ record: PlaybackProgress) -> some View {
        let content = HistoryRow(
            record: record,
            siteName: siteName(for: record.key),
            isSelected: isSelecting ? isSelected(record.key) : nil
        )
        if isSelecting {
            selectableRow(record.key, content: content)
        } else if let targetSite = availableSite(for: record.key) {
            NavigationLink {
                VodDetailView(model: model, site: targetSite, vodID: record.key.vodID)
            } label: {
                content
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func favoriteRow(_ favorite: Favorite) -> some View {
        let targetSite = availableSite(for: favorite.key)
        let content = FavoriteRow(
            favorite: favorite,
            siteName: siteName(for: favorite.key),
            isOpenable: targetSite != nil,
            isSelected: isSelecting ? isSelected(favorite.key) : nil
        )
        if isSelecting {
            selectableRow(favorite.key, content: content)
        } else if let targetSite {
            NavigationLink {
                VodDetailView(model: model, site: targetSite, vodID: favorite.key.vodID)
            } label: {
                content
            }
        } else {
            content
        }
    }

    /// 多选态的行：整行可点，点一下切换选中（**不导航**），左侧圆点在 ``HistoryRow``/``FavoriteRow`` 里画。
    private func selectableRow(_ key: PlaybackKey, content: some View) -> some View {
        Button {
            toggleSelection(key)
        } label: {
            content
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具栏

    /// 范围下拉：播放历史 / 收藏记录（当前项打勾）。
    ///
    /// 用工具栏左键承载（而不是自绘导航栏下拉）—— 按 `docs/UI 规范.md`，
    /// 业务视图不自绘系统控件，切换范围在原生语义里就是一个 `Menu`。
    private var scopeMenu: some View {
        Menu {
            ForEach(LibraryScope.allCases, id: \.self) { candidate in
                Button {
                    scope = candidate
                } label: {
                    if candidate == scope {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                }
            }
        } label: {
            Label(scope.displayName, systemImage: scope.icon)
        }
    }

    private var selectButton: some View {
        Button(isSelecting ? "完成" : "多选") {
            isSelecting.toggle()
            if !isSelecting {
                selection = []
            }
        }
        .disabled(currentRowCount == 0)
    }
}
