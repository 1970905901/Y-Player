import AVFoundation
import CatVodPlayer
import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 把自研 FFmpeg 内核的画面层（`FFmpegVideoSurface.layer`，一层 `AVSampleBufferDisplayLayer`）
/// 挂进 SwiftUI 的宿主视图。
///
/// 与 ``MpvVideoView`` 同一套路（宿主实现共用 ``LayerHostView``）：
/// 视图只做「挂层 + 跟随尺寸」，层的生命周期归 ``FFmpegVideoSurface``（会话持有它）。
struct FFmpegVideoView: UIViewRepresentable {
    let surface: FFmpegVideoSurface

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

/// 把自研 FFmpeg 内核的画面层挂进 SwiftUI 的宿主视图（macOS）。
struct FFmpegVideoView: NSViewRepresentable {
    let surface: FFmpegVideoSurface

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
