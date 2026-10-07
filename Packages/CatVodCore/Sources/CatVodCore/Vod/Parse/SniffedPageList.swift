import Foundation

/// 已嗅探到的「播放页」列表（上游 `CustomWebView` 的 `LinkedHashSet<String> urls` + `MAX_URLS`）。
///
/// 为什么需要它：解析页里常有「播放页套播放页」（`player.*https?://`）的结构，
/// 上游遇到这种请求会**再开一个 Web 嗅探窗口**去处理内层播放页；为了防止无限递归，
/// 它用一个有上限的集合去重。这段「最多开几个、什么时候清空」是协议事实，独立成值类型便于单测。
///
/// 逐条对齐上游 `CustomWebView.addUrl`：
/// - 超过上限（`> MAX_URLS`）时**先整体清空**再插入；
/// - 已存在则返回 `false`（不重复开窗口）。
public struct SniffedPageList: Sendable, Hashable {
    /// 上限（上游 `MAX_URLS = 5`）。
    public static let maximum = SniffRules.maximumDetectedPages

    /// 已记录的顺序（按插入顺序，等价上游 `LinkedHashSet` 的迭代顺序）。
    public private(set) var urls: [String] = []

    public init() {}

    /// 记录一个播放页地址；返回 `true` 表示是新地址，调用方应当为它再开一次嗅探。
    public mutating func insert(_ url: String) -> Bool {
        guard !url.isEmpty else {
            return false
        }
        if urls.count > Self.maximum {
            urls.removeAll()
        }
        guard !urls.contains(url) else {
            return false
        }
        urls.append(url)
        return true
    }
}
