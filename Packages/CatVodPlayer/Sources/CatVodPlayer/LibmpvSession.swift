import Foundation

/// 会话工厂：有 libmpv 就建真会话，没有就返回 nil（`MpvEngine` 据此报「内核不可用」）。
///
/// 单独放一个类型而不是让引擎直接 `#if canImport`：引擎只对着 seam 编程，
/// 「依赖在不在」这件事只有 ``MpvAvailability`` 与这里知道。
public enum MpvSessionFactory {
    /// - Parameter videoSurface: 画面层（MoltenVK 路径）。传 nil 只建「能解码、没画面」的会话 ——
    ///   只有单测这么用；生产必须给（见 `MpvVideoSurface`）。
    public static func make(videoSurface: MpvVideoSurface? = nil) -> (any MpvSession)? {
        #if canImport(Libmpv)
        return LibmpvSession(videoSurface: videoSurface)
        #else
        return nil
        #endif
    }
}

#if canImport(Libmpv)
import Libmpv

/// libmpv 的真实会话：**全工程唯一的 `mpv_*` 调用点**。
///
/// 设计取舍：
/// - 薄壳：只做两件事 —— 把 `mpv_*` 的负整数返回翻成人话、把事件翻成 ``MpvSessionEvent``；
/// - **不管渲染**：第 3 步的 PoC 定了 SW / MoltenVK / GL 之后，在这里补 `vo` 与 render API 即可，
///   `MpvEngine` 与 seam 都不用动；
/// - `@unchecked Sendable` 的理由：句柄只在 `MpvEngine`（actor）内部使用，跨线程共享由 actor 串行化保证。
final class LibmpvSession: MpvSession, @unchecked Sendable {
    private var handle: OpaquePointer?
    /// `destroy()` 必须**幂等**：引擎 teardown 与 `deinit` 都可能调，重复 `mpv_terminate_destroy` 会崩。
    private var destroyed = false
    /// 渲染路径（M03P1 第 3 步）：MoltenVK 要的那层 `CAMetalLayer`。nil = 只解码不出画（单测路径）。
    private let videoSurface: MpvVideoSurface?

    init?(videoSurface: MpvVideoSurface? = nil) {
        guard let handle = mpv_create() else {
            return nil
        }
        self.handle = handle
        self.videoSurface = videoSurface
    }

    deinit {
        destroy()
    }

    func setOption(name: String, value: String) {
        guard let handle, !destroyed else { return }
        // 失败只忽略：选项名在不同 libmpv 版本里有差异，不该因此让加载失败（真出问题会落进 mpv 日志）。
        _ = mpv_set_option_string(handle, name, value)
    }

    func initialize() -> String? {
        guard let handle, !destroyed else { return "libmpv 会话已销毁" }
        applyVideoOutputOptions()
        let code = mpv_initialize(handle)
        return code < 0 ? Self.message(code) : nil
    }

    /// 渲染路径的四个选项（M03P1 第 3 步，逐条对齐 MPVKit 官方 Demo 的 `setupMpv`）。
    ///
    /// **必须在 `mpv_initialize` 之前设**：这几个都是启动期固定的选项，初始化后再设不生效。
    /// 这也是这一层唯一与「画面」有关的代码 —— 引擎（`MpvEngine`）与 seam 都不认识渲染。
    private func applyVideoOutputOptions() {
        guard let surface = videoSurface else {
            return
        }
        // 字符串形式的 wid 与 Demo 的 int64 形式等价：mpv 的字符串选项会按声明类型解析。
        setOption(name: "wid", value: String(surface.windowID))
        setOption(name: "vo", value: "gpu-next")
        setOption(name: "gpu-api", value: "vulkan")
        setOption(name: "gpu-context", value: "moltenvk")
    }

    func observe(property: String, id: UInt64, format: String) {
        guard let handle, !destroyed else { return }
        _ = mpv_observe_property(handle, id, property, Self.format(named: format))
    }

    func command(_ args: [String]) -> String? {
        guard let handle, !destroyed else { return "libmpv 会话已销毁" }
        // C API 要 `const char **`：先把字符串拷成 C 串，再用指针数组传，末尾补 NULL。
        // 坑一：`mpv_command` 的形参在 Swift 里是 `UnsafeMutablePointer<UnsafePointer<CChar>?>`，
        //       所以数组元素必须是**不可变指针 + 可选**（可变指针数组过不了类型检查）。
        // 坑二：`[UnsafePointer<CChar>]` 不会自动变 `[UnsafePointer<CChar>?]`，得显式 `Optional(...)`。
        let owned = args.map { strdup($0) }.compactMap { $0 }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { Optional(UnsafePointer($0)) }
        pointers.append(nil)
        let code = mpv_command(handle, &pointers)
        return code < 0 ? Self.message(code) : nil
    }

    func waitEvent(timeout: Double) -> MpvSessionEvent {
        // 已销毁：当作会话结束（引擎的循环据此退出），而不是崩在野指针上。
        guard let handle, !destroyed else { return .shutdown }
        guard let event = mpv_wait_event(handle, timeout) else { return .none }
        return Self.sessionEvent(event.pointee)
    }

    func destroy() {
        guard let handle, !destroyed else { return }
        destroyed = true
        self.handle = nil
        mpv_terminate_destroy(handle)
    }

    // MARK: - 事件 / 值的翻译

    /// `mpv_event` → 我们的事件（只认引擎要用的那几种，其余给 `.other`）。
    private static func sessionEvent(_ event: mpv_event) -> MpvSessionEvent {
        switch event.event_id {
        case MPV_EVENT_NONE:
            return .none
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            return .endFile(reason: endFileReason(event))
        case MPV_EVENT_PROPERTY_CHANGE:
            return propertyEvent(event)
        default:
            return .other
        }
    }

    /// 属性变化事件。属性的 id 不在 `mpv_event_property` 里，而是事件自带的 `reply_userdata`
    /// （`mpv_observe_property` 的第 2 个参数，就是我们自己的 id）。
    private static func propertyEvent(_ event: mpv_event) -> MpvSessionEvent {
        guard let data = event.data else { return .other }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        return .property(id: event.reply_userdata, value: propertyValue(property))
    }

    /// 属性值：只支持我们 observe 的几种格式（其余当「暂时没有值」）。
    private static func propertyValue(_ property: mpv_event_property) -> MpvPropertyValue {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_INT64:
            return .integer(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_FLAG:
            // `MPV_FORMAT_FLAG` 的底层是 C 的 `int`（不是 `bool`、也不是 `int64_t`）。
            return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_STRING:
            guard let text = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else {
                return .none
            }
            return .string(String(cString: text))
        default:
            return .none
        }
    }

    /// `end-file` 的原因文字：只有 `error` 会被引擎判成失败（见 ``MpvEventMapping/isFailure(endFileReason:)``）。
    private static func endFileReason(_ event: mpv_event) -> String {
        guard let data = event.data else { return "unknown" }
        switch data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason {
        case MPV_END_FILE_REASON_ERROR:
            return "error"
        case MPV_END_FILE_REASON_EOF:
            return "eof"
        case MPV_END_FILE_REASON_STOP:
            return "stop"
        case MPV_END_FILE_REASON_QUIT:
            return "quit"
        case MPV_END_FILE_REASON_REDIRECT:
            return "redirect"
        default:
            return "unknown"
        }
    }

    /// 属性格式名（seam 用的是文字，避免把 `mpv_format` 带进 seam）→ `mpv_format`。
    private static func format(named name: String) -> mpv_format {
        switch name {
        case "double":
            return MPV_FORMAT_DOUBLE
        case "flag":
            return MPV_FORMAT_FLAG
        case "int64":
            return MPV_FORMAT_INT64
        case "string":
            return MPV_FORMAT_STRING
        default:
            return MPV_FORMAT_NONE
        }
    }

    /// `mpv_error` 负整数 → 人话（带原始码，便于对照 libmpv 文档）。
    private static func message(_ code: Int32) -> String {
        guard let text = mpv_error_string(code) else {
            return "libmpv 错误码 \(code)"
        }
        return "\(String(cString: text))（\(code)）"
    }
}
#endif
