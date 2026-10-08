import Foundation

/// 分组条里分组的**显示顺序**（对齐上游 `setting/SiteGroupOrderStore.java` 的排序三件套）。
///
/// 上游把「用户拖过的顺序」存进偏好（按接口分桶，键前缀 `site_group_order_`）；这里只做**纯排序** ——
/// 界面把存下来的顺序传进来、拿到排好的列表，存哪、怎么存是 UI 层的事（与 `LivePassBook` 一个套路）。
public enum SiteGroupOrder {
    /// 按存的顺序重排：存过的按存的次序排前面，**没存过的保持默认顺序接在后面**。
    public static func order(_ groups: [String], savedOrder: [String]) -> [String] {
        let available = normalized(groups)
        guard !available.isEmpty else { return [] }
        var remaining = available
        var result: [String] = []
        for group in normalized(savedOrder) where remaining.contains(group) {
            remaining.removeAll { $0 == group }
            result.append(group)
        }
        for group in available where remaining.contains(group) {
            remaining.removeAll { $0 == group }
            result.append(group)
        }
        return result
    }

    /// 拖动排序后与「完整顺序」合并：可见分组的相对次序按用户拖的来，**隐藏分组的槽位保留**。
    ///
    /// 为什么要合并：分组条里只显示有站点的分组，但排序要按「全集」存 ——
    /// 否则一个分组因为当下不可见就被排到末尾，下次它出现时位置就乱了。
    public static func mergedVisibleOrder(fullOrder: [String], visibleOrder: [String]) -> [String] {
        let full = normalized(fullOrder)
        let visible = normalized(visibleOrder)
        if visible.isEmpty { return full }

        let fullSet = Set(full)
        let knownVisible = visible.filter { fullSet.contains($0) }
        let visibleSet = Set(knownVisible)
        var result: [String] = []
        var visibleIndex = 0
        for group in full {
            if visibleSet.contains(group), visibleIndex < knownVisible.count {
                result.append(knownVisible[visibleIndex])
                visibleIndex += 1
            } else {
                result.append(group)
            }
        }
        for group in visible where !result.contains(group) {
            result.append(group)
        }
        return normalized(result)
    }

    /// 把一个分组上/下移一格（`direction` 只能是 -1 / 1）；越界、找不到、方向非法都返回 false 且不动数组。
    public static func move(_ groups: inout [String], group: String, direction: Int) -> Bool {
        guard direction == -1 || direction == 1 else { return false }
        guard let from = groups.firstIndex(of: group) else { return false }
        let to = from + direction
        guard to >= 0, to < groups.count else { return false }
        groups.swapAt(from, to)
        return true
    }

    /// 去空、去重、保序（对齐上游 `normalize`）。
    public static func normalized(_ groups: [String]) -> [String] {
        var result: [String] = []
        for group in groups {
            let value = group.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || result.contains(value) { continue }
            result.append(value)
        }
        return result
    }
}
