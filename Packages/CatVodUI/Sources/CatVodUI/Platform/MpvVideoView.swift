import CatVodPlayer
import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 把 libmpv 的画面层（`MpvVideoSurface.layer`）挂进 SwiftUI 的宿主视图。
///
/// 为什么自己写宿主：MPV 内核要的不是 `AVPlayer` 那样的「播放器控件」，而是一层 **CAMetalLayer**
/// （`wid` 指向它，mpv 经 MoltenVK 直接往上画）—— 系统那套 `VideoPlayer` 在这里没有对应物。
///
/// 约定：
/// - 视图只做「挂层 + 跟随尺寸」（宿主实现见 ``LayerHostView``）；
///   层的生命周期归 `MpvVideoSurface`（引擎持有它），视图重建也不会把 mpv 正在画的那层换掉；
/// - 背景黑，与系统内核的画面衬底一致（留边不露页面底色）。
struct MpvVideoView: UIViewRepresentable {
    let surface: MpvVideoSurface

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.attach(surface.layer)
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.attach(surface.layer)
    }
}

#else
import AppKit

/// 把 libmpv 的画面层挂进 SwiftUI 的宿主视图（macOS）。
struct MpvVideoView: NSViewRepresentable {
    let surface: MpvVideoSurface

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.attach(surface.layer)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.attach(surface.layer)
    }
}
#endif
