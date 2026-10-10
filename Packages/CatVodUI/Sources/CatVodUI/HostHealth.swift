/// 宿主**现探**结果（M22P1）。
///
/// 与 ``JS2PHostStatus`` 的分工：那个是「最近一次刷新站点清单」的**结论**（可能几分钟前的），
/// 这个只回答一个问题 —— **宿主现在这一刻还活着吗**。
///
/// 为什么要有它：`JS2PHostService.health()` 一直存在、注释还写着「界面据此提示」，
/// 但**没有任何调用点** —— 宿主半路崩掉时，界面照样写着「宿主运行中」，
/// 用户看到的是「明明显示运行中，站点却打不开」。
public enum HostHealth: Sendable, Equatable {
    /// 还没探过（或当前接口不需要宿主）。
    case unknown
    case online
    case offline

    /// 一句话（视图直接用；别在视图里各写一套）。
    public var text: String {
        switch self {
        case .unknown: "尚未检测"
        case .online: "在线（刚探过）"
        case .offline: "离线 —— 宿主可能崩了，点「重启宿主」"
        }
    }
}
