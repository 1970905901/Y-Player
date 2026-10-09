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

    /// `MpvEngine` 是否已实装（M03P1 第 4 步）。
    ///
    /// **实装 ≠ 可用**：引擎代码齐了（加载 / 播放 / 暂停 / 跳转 / 倍速 / 轨道选择 / 进度 / 状态，
    /// 见 `MpvEngine` + `MpvEventMapping`），但**画面输出（渲染路径）还没定** ——
    /// 第 3 步要在 Mac/真机上做 SW / MoltenVK / GL 的 PoC。没有画面就等于不能用，
    /// 所以 `PlayerEngineKind.mpv.isAvailable` 仍要看 ``isVideoOutputReady``。
    public static let isEngineImplemented = true

    /// MPV 渲染路径是否已定并接线（M03P1 第 3 步）。
    ///
    /// 路径已定：**MoltenVK → `CAMetalLayer`**，逐条对齐 MPVKit 官方 Demo
    /// （`wid` 传 layer 指针 + `vo=gpu-next` / `gpu-api=vulkan` / `gpu-context=moltenvk`，
    /// 四项都在 `mpv_initialize` 之前设，见 ``MpvVideoSurface`` 与 `LibmpvSession.applyVideoOutputOptions`）；
    /// 播放页也接上了（选 MPV 时自建画面层 + 最小控制条），所以这里为 true。
    ///
    /// ⚠️ 剩下的是**真机/模拟器确认**：Metal 后端在 MPVKit 里是补丁级支持，第一次跑要盯
    /// 「有没有画面、有没有 `dyld` 缺库、HDR 会不会崩」。真出问题只动 `LibmpvSession` 的渲染选项。
    public static let isVideoOutputReady = true

    /// 自研 `FFmpegEngine`（M4）是否已实装。
    public static let isFFmpegEngineImplemented = false
}
