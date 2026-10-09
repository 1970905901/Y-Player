import QuartzCore

/// libmpv 的画面目标：一层 `CAMetalLayer`（M03P1 第 3 步选定的渲染路径 —— MoltenVK）。
///
/// 依据 MPVKit 官方 Demo（`Demo/Demo-iOS/Demo-iOS/Player/Metal/MPVMetalViewController.swift`）：
/// - `wid` 传这层 layer 的**指针数值**；
/// - 同时设 `vo=gpu-next` / `gpu-api=vulkan` / `gpu-context=moltenvk` —— mpv 经 MoltenVK 直接画进这层。
///   三个选项都必须在 `mpv_initialize` **之前**设好（启动期固定），所以由 `LibmpvSession` 在初始化前补。
///
/// 为什么单独一个类型、而不是直接传 `CAMetalLayer`：
/// - 引擎与界面都要持有它（引擎拿指针、界面把 layer 挂进视图层级），生命周期必须比 mpv 会话长；
/// - `CatVodPlayer` 只依赖 QuartzCore，不 import UIKit/AppKit —— 两端的宿主视图在 `CatVodUI/Platform` 里。
///
/// `@unchecked Sendable`：layer 只在主线程创建与布局（由界面层保证），引擎侧只读它的指针数值。
public final class MpvVideoSurface: @unchecked Sendable {
    /// 画面层。界面层负责把它挂进视图层级，并同步 `frame` / `contentsScale`。
    public let layer = CAMetalLayer()

    public init() {
        // 与 Demo 一致：直接在 layer 上出图，不需要 CPU 读回。
        layer.framebufferOnly = true
        layer.isOpaque = true
    }

    /// `wid` 选项要的整数值（对象地址）。
    var windowID: Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    }
}
