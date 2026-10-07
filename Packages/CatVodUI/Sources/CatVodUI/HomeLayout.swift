import Foundation

/// 首页内容列表的展示方式（设置 → 首页 → 展示方式）。
///
/// 对应参考图上的「纵向展示 / 横向展示」：纵向就是现在的列表行（海报 + 标题 + 备注），
/// 横向是海报网格。**两种布局共用同一份数据**（分类、筛选、分页都不变），
/// 所以这个偏好只需要界面读一次，不牵动请求逻辑。
///
/// 持久化在 `UserDefaults`（键 `yplayer.homeLayout`），与播放内核/解码方式同一套做法。
public enum HomeLayout: String, Sendable, CaseIterable, Hashable {
    /// 纵向展示：一列内容行（默认，等同 M2 的首页观感）。
    case vertical
    /// 横向展示：海报网格（每行多张）。
    case horizontal

    /// 界面展示名（设置页与首页共用，避免两处写不同文案）。
    public var displayName: String {
        switch self {
        case .vertical: "纵向展示"
        case .horizontal: "横向展示"
        }
    }
}
