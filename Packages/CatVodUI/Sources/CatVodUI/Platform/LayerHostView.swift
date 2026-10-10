import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 挂任意 `CALayer` 的宿主视图（iOS）：铺满自己，尺寸变化时同步 `frame` 与 `contentsScale`。
///
/// 谁在用：``MpvVideoView``（CAMetalLayer）与 ``FFmpegVideoView``（AVSampleBufferDisplayLayer）——
/// 两边宿主逻辑一模一样，就这一份（M04P13 从 `MpvVideoView` 里提出来）。
final class LayerHostView: UIView {
    private weak var attachedLayer: CALayer?

    func attach(_ layer: CALayer) {
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer.addSublayer(layer)
            attachedLayer = layer
        }
        syncFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncFrame()
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        // 关掉隐式动画：尺寸变化时不做动画，否则画面会拖影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer.frame = bounds
        attachedLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
    }
}

#else
import AppKit

/// 挂任意 `CALayer` 的宿主视图（macOS）。
final class LayerHostView: NSView {
    private weak var attachedLayer: CALayer?

    func attach(_ layer: CALayer) {
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
            attachedLayer = layer
        }
        syncFrame()
    }

    override func layout() {
        super.layout()
        syncFrame()
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer.frame = bounds
        attachedLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
#endif
