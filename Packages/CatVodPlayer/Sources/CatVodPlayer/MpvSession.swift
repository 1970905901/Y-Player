import Foundation

/// libmpv 会话要用的**最小接口**（seam）。
///
/// 为什么要有这一层，而不是在引擎里直接调 C：
/// 1. **第 3 步的渲染路径还没定**（SW / MoltenVK / GL，需要 Mac/真机做 PoC），画面在 CI 上验不了；
///    但「加载 / 播放 / 暂停 / 跳转 / 进度 / 事件映射 / 状态机」这些语义现在就能钉住 ——
///    用假会话在 CI 上跑（`MpvEngineTests`），真机到时只补渲染那一段；
/// 2. 真的 C 调用收在 `LibmpvSession.swift` 一个文件里，第 3 步换渲染路径时不动上层。
///
/// 约定：
/// - 方法是**同步**的（对应 C 的阻塞调用），由 `MpvEngine`（actor）串行调用；返回 `String?` 的地方
///   「非 nil 即错误描述」（C API 返回负整数，这里翻成人话）；
/// - `Sendable` 的合规性由实现方负责，理由写在各实现上（`LibmpvSession` 只在 `MpvEngine` 内部使用）。
public protocol MpvSession: AnyObject, Sendable {
    /// 设置选项（`mpv_set_option_string`）—— 必须在 ``initialize()`` **之前**调用才生效。
    func setOption(name: String, value: String)
    /// 初始化（`mpv_initialize`）；失败返回错误描述。
    func initialize() -> String?
    /// 观察属性（`mpv_observe_property`）：变化会作为 ``MpvSessionEvent/property(id:value:)`` 回来。
    func observe(property: String, id: UInt64, format: String)
    /// 执行命令（`mpv_command`，例如 `["loadfile", url, "replace"]`）；失败返回错误描述。
    func command(_ args: [String]) -> String?
    /// 读一个属性的字符串形式（`mpv_get_property_string`）；没有值返回 nil。
    ///
    /// 用途：`track-list` 这种**结构化属性** —— mpv 会把它转成 JSON 字符串，
    /// 拉起轨道列表时读一次就够（轨迹变化时再读，不必用属性观察去接 node）。
    func propertyString(_ name: String) -> String?
    /// 取下一件事件（`mpv_wait_event`，最多等 `timeout` 秒；超时给 `.none`）。
    func waitEvent(timeout: Double) -> MpvSessionEvent
    /// 销毁（`mpv_terminate_destroy`）；实现要保证**幂等**（引擎与 deinit 都可能调）。
    func destroy()
}

/// 会话事件：从 libmpv 的一堆事件里只留引擎真正要用的那几种。
///
/// 不直接暴露 `mpv_event`：那会让状态机没法在 CI 上单测（要构造 C 结构体），
/// 也会把渲染相关的事件一起拖进来。
public enum MpvSessionEvent: Equatable, Sendable {
    /// 超时：这段时间里没有事件。
    case none
    /// 会话被销毁（`MPV_EVENT_SHUTDOWN`）。
    case shutdown
    /// 文件已加载完（`MPV_EVENT_FILE_LOADED`）—— 可以开始播。
    case fileLoaded
    /// 播放结束或失败（`MPV_EVENT_END_FILE`）；`reason` 用 mpv 的枚举文字（`eof` / `error` / `stop`…）。
    case endFile(reason: String)
    /// 观察的属性变了。
    case property(id: UInt64, value: MpvPropertyValue)
    /// 其它事件（日志、未观察的属性…）：引擎忽略，保留形状便于排查。
    case other
}

/// 属性的值：我们只 observe 少数几个属性，够用就好（`MPV_FORMAT_*` 的一个子集）。
public enum MpvPropertyValue: Equatable, Sendable {
    /// `MPV_FORMAT_NONE`（属性暂时没有值）。
    case none
    /// `MPV_FORMAT_FLAG`。
    case flag(Bool)
    /// `MPV_FORMAT_INT64`。
    case integer(Int64)
    /// `MPV_FORMAT_DOUBLE`。
    case double(Double)
    /// `MPV_FORMAT_STRING`。
    case string(String)

    /// 当数值用（不是数值就 `nil`）：映射层用它，省得每处都 switch 一遍。
    public var doubleValue: Double? {
        switch self {
        case let .double(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    /// 当开关用（不是开关就 `nil`）。
    public var boolValue: Bool? {
        switch self {
        case let .flag(value): value
        case let .integer(value): value != 0
        default: nil
        }
    }
}
