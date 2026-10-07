import Foundation

/// MPV 内核的**编译期可用性**。
///
/// 这个类型存在的唯一理由：把「MPVKit 依赖是否真的让我们能 `import Libmpv`」变成**可断言的事实**。
///
/// 之前 `MpvEngine` 用 `#if canImport(Libmpv)` 隔离，但那个条件从来没被验证过 ——
/// 于是「引擎还没实现」和「依赖没接对」在代码里看起来一模一样。
/// 现在由 `MpvAvailabilityTests` 把它钉死：CI 一旦不能导入 libmpv，测试立刻红。
public enum MpvAvailability {
    /// 当前构建能否导入 libmpv（`Libmpv` 模块是否在搜索路径里）。
    public static var canImportLibmpv: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    /// 自研 FFmpegEngine（M4）要用的 Libav* 是否可用 —— 它们与 libmpv 同源，
    /// 若为 false 说明 MPVKit 只暴露了 libmpv 而没暴露 FFmpeg 头文件。
    public static var canImportLibavcodec: Bool {
        #if canImport(Libavcodec)
        return true
        #else
        return false
        #endif
    }

    /// 供界面/日志展示的一行说明（避免各处各写一套）。
    public static var summary: String {
        "libmpv=\(canImportLibmpv ? "可用" : "不可用")，Libavcodec=\(canImportLibavcodec ? "可用" : "不可用")"
    }

    // MARK: - 实装状态（与「依赖是否链接」严格分开）

    /// `MpvEngine` 是否已实装。
    ///
    /// 依赖已接（`canImportLibmpv == true`）**不等于**引擎可用：渲染路径还没定（M03P1 第 3 步）、
    /// 引擎代码还没写（第 4 步）。因此 `PlayerEngineKind.mpv.isAvailable` 继续为 false，
    /// 界面就不会宣称一个播不了的内核「可用」。
    public static let isEngineImplemented = false

    /// 自研 `FFmpegEngine`（M4）是否已实装。
    public static let isFFmpegEngineImplemented = false
}
