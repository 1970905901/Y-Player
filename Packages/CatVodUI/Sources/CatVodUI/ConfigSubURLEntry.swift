import CatVodCore
import Foundation

/// 多仓（`SourceConfig.urls`）里的一条子配置：**原文 + 解析结果**（M18P2）。
///
/// `url == nil` 表示这条**点不动**（相对地址但当前配置没有基准地址，或压根不是合法 URL）——
/// 界面据此把那一行置灰并写明原因，不做「点了没反应」。
struct ConfigSubURLEntry: Sendable, Equatable, Identifiable {
    var raw: String
    var url: URL?

    var id: String { raw }
}

/// 多仓条目的构造：把配置里的 `urls` 变成可点的一条条。
enum ConfigSubURLs {
    /// - Parameter origin: 当前配置的地址（相对路径的基准）；内联配置没有基准，给 nil。
    static func entries(_ raw: [String], relativeTo origin: URL?) -> [ConfigSubURLEntry] {
        raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { text in
                // 绝对地址直接用；相对地址按**当前配置地址**解析（配置里 `./sub.json` 这种写法很常见）。
                // 解析不出来就留 nil，让界面说清「这条为什么点不动」。
                ConfigSubURLEntry(raw: text, url: ConfigLocator.resolveURL(text, relativeTo: origin))
            }
    }
}
