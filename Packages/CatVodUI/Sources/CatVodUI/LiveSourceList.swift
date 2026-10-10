import CatVodCore
import Foundation

/// 直播设置里「直播源」一行的模型。
///
/// 一个配置里可以有多个直播源（`SourceConfig.lives`），上游也是「先选源再看分组」
/// （`LiveConfig.getLives()` + `setHome`）。本项目此前只有持久化（`AppModel.selectedLiveKey`）
/// 而**没有入口**，所以配了多源的接口在界面上根本切不了 —— 这里把「一行显示什么」定下来，
/// 界面不再各写一遍。
struct LiveSourceRow: Identifiable, Equatable {
    /// 源名（`LiveSource.name`，也是持久化用的键）。
    var name: String
    /// 第二行摘要：类型 +（已解析时）频道数。
    var detail: String
    /// 是不是当前选中的源。
    var isSelected: Bool

    var id: String { name }
}

/// 直播源列表的行模型构造。
enum LiveSourceList {
    /// 全部行（顺序即配置里的顺序）。
    ///
    /// `loaded` 传**当前已解析**的那份清单：只有名字对得上时摘要里才报频道数 ——
    /// 没解析过的源我们并不知道它有多少频道，不能编。
    static func rows(_ sources: [LiveSource], selected: String, loaded: LiveSource?) -> [LiveSourceRow] {
        sources.map { row($0, selected: selected, loaded: loaded) }
    }

    /// 单个源的一行。
    ///
    /// 频道数只在**已解析的那份**里才有（配置里的源 `groups` 是空的）—— 所以计数要取 `loaded`，
    /// 不能取 `source`（踩过：写成了 `source.channelCount`，界面上永远看不到频道数，单测抓住了）。
    static func row(_ source: LiveSource, selected: String, loaded: LiveSource?) -> LiveSourceRow {
        let type = typeName(source.type)
        // 内核注入源（`core`，如 tvbus）：本平台没有对应引擎 —— 直接写在那一行上，
        // 别让用户点进去才发现（M20P1）。
        if source.requiresCoreEngine {
            return LiveSourceRow(
                name: source.name,
                detail: "\(type) · 不支持 core 内核（\(source.coreEngine)）",
                isSelected: source.name == selected
            )
        }
        let detail: String
        if let loaded, loaded.name == source.name, loaded.channelCount > 0 {
            detail = "\(type) · \(loaded.channelCount) 个频道"
        } else {
            detail = type
        }
        return LiveSourceRow(name: source.name, detail: detail, isSelected: source.name == selected)
    }

    /// 类型文案（上游 `Live.type`：`0` 直读清单，`3` Spider）。
    ///
    /// 其它取值不猜含义，原样写出来（协议里 `type` 是开放的整数）。
    static func typeName(_ type: Int) -> String {
        switch type {
        case 0: "清单（TXT / M3U / JSON）"
        case 3: "Spider（JS）"
        default: "type \(type)"
        }
    }
}
