import CatVodCore
import CoreGraphics

/// 海报卡的形状与比例（M23P1）：把配置里的 ``CardStyle`` 换算成网格里实际用的两个数。
///
/// 为什么单拎出来：`DiscoverPosterCard` 是视图（不好直接单测），而「配置说要多宽、是不是圆的」
/// 是**纯换算** —— 这类换算错了（比如把 `land=1` 当竖向）在界面上一眼看不出来，但会在真机上
/// 显示成完全不同的版式。所以换算有单测，视图只负责画。
enum PosterCardLayout {
    /// 没有声明样式时的比例：参考视频里约 2:3（竖幅海报）。
    ///
    /// **只有配置真的声明了 `style` 才照它来** —— 默认策略不跟着 `CardStyle.resolvedRatio`
    /// 的兜底值走（那是协议默认 rect=0.75），否则所有没写样式的配置都会突然变版式。
    static let fallbackRatio: CGFloat = 2.0 / 3.0

    /// 网格里用的宽高比。
    static func ratio(for style: CardStyle?) -> CGFloat {
        guard let style else {
            return fallbackRatio
        }
        return CGFloat(style.resolvedRatio)
    }

    /// 是不是圆形卡（配置里 `type=oval` 或 `circle=1`）。
    static func isCircular(_ style: CardStyle?) -> Bool {
        style?.kind == .oval
    }

    /// 圆形卡按正圆画（`ratio` 对圆没有意义）。
    static func ratio(for style: CardStyle?, circular: Bool) -> CGFloat {
        circular ? 1 : ratio(for: style)
    }
}
