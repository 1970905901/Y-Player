import Foundation

/// 直播收藏的取值语义（上游 `LiveConfig.applyKeepsToGroups` + `LiveActivity` 的收藏开关）。
public enum LiveFavorites {
    /// 这个频道已经收藏了吗（上游 `Keep.exist(item.getName())`）。
    public static func contains(_ channelName: String, in favorites: [LiveFavorite]) -> Bool {
        favorites.contains { $0.name == channelName }
    }

    /// 切换收藏：已收藏就删掉，否则插到**最前**（最近收藏的排最前），顺手去掉同名重复项。
    public static func toggling(_ favorite: LiveFavorite, in favorites: [LiveFavorite]) -> [LiveFavorite] {
        guard !favorite.name.isEmpty else {
            return favorites
        }
        var updated = favorites.filter { $0.name != favorite.name }
        if updated.count == favorites.count {
            updated.insert(favorite, at: 0)
        }
        return updated
    }

    /// 「收藏」分组：把清单里被收藏的频道收进来（上游 `LiveConfig.applyKeepsToGroups`）。
    ///
    /// 三条与上游一致的语义：
    /// - 顺序跟**清单**一致（上游遍历清单、命中才追加，不看收藏时间）；
    /// - 只从「非收藏组」里取（上游 `.filter(group -> !group.isKeep())`，否则收藏组会自己喂自己）；
    /// - 频道对象是清单里的那一份（地址 / header / 时移 / EPG 都跟着清单），不是收藏时的快照。
    ///
    /// 一个频道都没命中（还没收藏，或收藏的频道已经不在清单里）返回 `nil`：界面就别显示这一组。
    public static func group(
        in source: LiveSource,
        favorites: [LiveFavorite],
        title: String = LiveGroup.keepName
    ) -> LiveGroup? {
        let names = Set(favorites.map(\.name))
        var channels: [LiveChannel] = []
        var seen = Set<String>()
        guard !names.isEmpty else {
            return nil
        }
        for group in source.groups where !group.isKeep {
            for channel in group.channels where names.contains(channel.name) {
                if seen.insert(channel.name).inserted {
                    channels.append(channel)
                }
            }
        }
        guard !channels.isEmpty else {
            return nil
        }
        var favoritesGroup = LiveGroup(name: title)
        favoritesGroup.channels = channels
        return favoritesGroup
    }
}
