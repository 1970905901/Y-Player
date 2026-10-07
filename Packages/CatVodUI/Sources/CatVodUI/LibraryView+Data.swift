import CatVodCore
import CatVodStore
import SwiftUI

// 「追剧」页的数据逻辑（与视图分离，便于阅读与后续单测）。

extension LibraryView {
    /// 当前范围的记录条数（决定「多选」按钮是否可用）。
    var currentRowCount: Int {
        scope == .history ? records.count : favorites.count
    }

    /// 重新读取两个 store（都是内存实现，代价可忽略）。
    func reload() async {
        records = await model.progressStore.all()
        favorites = await model.favoriteStore.favorites()
        // 记录被别处删掉（例如详情页「从头播放」清了进度）时，清掉已失效的选择。
        let alive = Set(scope == .history ? records.map(\.key.storageKey) : favorites.map(\.key.storageKey))
        selection = selection.intersection(alive)
    }

    /// 播放历史：滑动删除。
    func deleteHistory(at offsets: IndexSet) async {
        let keys = offsets.compactMap { records.indices.contains($0) ? records[$0].key : nil }
        await removeRows(keys: keys)
    }

    /// 收藏记录：滑动删除。
    func deleteFavorites(at offsets: IndexSet) async {
        let keys = offsets.compactMap { favorites.indices.contains($0) ? favorites[$0].key : nil }
        await removeRows(keys: keys)
    }

    /// 多选删除（工具栏「删除」）。
    func deleteSelected() async {
        var keys: [PlaybackKey] = []
        switch scope {
        case .history:
            keys = records.filter { selection.contains($0.key.storageKey) }.map(\.key)
        case .favorites:
            keys = favorites.filter { selection.contains($0.key.storageKey) }.map(\.key)
        }
        await removeRows(keys: keys)
    }

    /// 按当前范围分发删除：历史清进度、收藏删收藏。
    func removeRows(keys: [PlaybackKey]) async {
        guard !keys.isEmpty else {
            return
        }
        switch scope {
        case .history:
            for key in keys {
                await model.progressStore.clear(for: key)
            }
        case .favorites:
            await model.favoriteStore.removeAll(for: keys)
        }
        selection = []
        await reload()
    }

    /// 记录所属站点：**必须在当前接口的可用站点里**，否则详情页拿不到站点、没法加载。
    func availableSite(for key: PlaybackKey) -> Site? {
        model.sites.first { $0.key == key.siteKey }
    }

    /// 该行是否已勾选（多选态下的行内圆点）。
    func isSelected(_ key: PlaybackKey) -> Bool {
        selection.contains(key.storageKey)
    }

    /// 切换某行的勾选状态。
    func toggleSelection(_ key: PlaybackKey) {
        if selection.contains(key.storageKey) {
            selection.remove(key.storageKey)
        } else {
            selection.insert(key.storageKey)
        }
    }

    /// 站点展示名：记录里没存站点名（老记录 / 换接口后站点改名）时按当前接口回退，最后退回 key。
    func siteName(for key: PlaybackKey) -> String {
        guard let site = model.allSites.first(where: { $0.key == key.siteKey }) else {
            return key.siteKey
        }
        return site.name.isEmpty ? site.key : site.name
    }

    var historyEmptyHint: String {
        "还没有播放记录：播放任意一集就会出现在这里（进度、片名、封面、站源、线路与集名一起记下来）。"
            + "注意：现在进度只存在内存里（杀进程即丢），落库在 M8。"
    }

    var favoritesEmptyHint: String {
        "还没有收藏：在影片详情页点工具栏的「收藏」即可加入这里。"
            + "收藏也只存在内存里（杀进程即丢），落库在 M8。"
    }
}
