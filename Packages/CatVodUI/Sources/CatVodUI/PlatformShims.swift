import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 平台差异 shim：把 iOS 15 / macOS 13 的差异集中在这里，业务代码不做散落的 `#if`。
public enum PlatformShims {
    /// 跨平台颜色（`Color` 在两平台同名，这里只留扩展点）。
    public static let accent = Color.accentColor

    /// 卡片圆角。
    public static let cardCornerRadius: CGFloat = 10
}

/// 站点可用性徽标：不可用站点在 UI 上必须给出原因，避免用户误判为「站点坏了」。
public struct SiteAvailabilityBadge: View {
    private let availability: SiteAvailability

    public init(availability: SiteAvailability) {
        self.availability = availability
    }

    public var body: some View {
        if let reason = availability.reason {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
