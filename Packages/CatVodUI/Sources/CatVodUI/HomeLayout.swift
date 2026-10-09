import Foundation

/// 首页内容列表的展示方式（设置 → 首页 → 展示方式）。
///
/// 对应参考图的两张截图（`发现页横向显示.jpg` / `发现页纵向显示.jpg`）：
///
/// - **纵向展示**＝图 2：分类横条 + 筛选行 + **3 列海报网格**，向下滚动自动接着加载下一页；
/// - **横向展示**＝图 1：按分类分成若干**分区**，每区一行**横向滑动**的海报，标题右侧带 `>`。
///
/// ⚠️ 两种模式**共用同一份站点接口**，但**取数方式不同**：
/// 纵向只取当前分类、翻页追加；横向要给每个分区各取一页（`HomeView+Data.loadSections`）。
///
/// ⚠️ 历史坑：这两个实现曾经**正好反着** —— `vertical` 给的是一列 `VodRow`、
/// `horizontal` 给的是网格，也就是说图 1 那种形态（分区横滑）根本不存在。
/// 改的时候别按名字猜，按上面这两行对照图。
///
/// 持久化在 `UserDefaults`（键 `yplayer.homeLayout`），与播放内核/解码方式同一套做法。
public enum HomeLayout: String, Sendable, CaseIterable, Hashable {
    /// 纵向展示：分类 + 筛选 + 网格 + 翻页（参考图 2）。
    case vertical
    /// 横向展示：按分类分区、每区一行横滑（参考图 1）。
    case horizontal

    /// 界面展示名（设置页与首页共用，避免两处写不同文案）。
    public var displayName: String {
        switch self {
        case .vertical: "纵向展示"
        case .horizontal: "横向展示"
        }
    }
}
