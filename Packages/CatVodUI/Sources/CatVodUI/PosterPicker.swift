import Foundation

/// 海报取图策略：**固定 / 随机 / 轮播**（TMDB 视图 · M11）。
///
/// 顶部大图与选集卡片的缩略图**共用这一套** —— 参考视频里两种位置的取图行为一致
/// （顶部那张会换、卡片每张也不同），所以策略只做「给一组图 + 一种模式 → 出当前该显示的图」，
/// 不碰网络、不碰视图，谁要就把同一份 `PosterPicker` 拿去用。
enum PosterMode: String, CaseIterable, Sendable {
    /// 永远第一张（TMDB 给的顺序即「主图优先」）。
    case fixed
    /// 每次进页面随机一张 —— 注意是**进页面定一次**，不是每步都变。
    case random
    /// 定时在若干张之间前进，到末尾回到开头。
    case rotate

    var displayName: String {
        switch self {
        case .fixed: "固定"
        case .random: "随机"
        case .rotate: "轮播"
        }
    }
}

/// 从一组图里取出「当前该显示的那张」。
///
/// `step` 由调用方驱动：`.rotate` 每次定时器触发 +1；`.fixed` / `.random` 忽略它。
/// `seed` 只在 `.random` 生效，**进页面时定一次**并全程不变 —— 每步都换种子会变成
/// 一张闪烁的图，那不像轮播，像坏了。
struct PosterPicker: Sendable {
    let images: [String]
    let mode: PosterMode

    func index(step: Int = 0, seed: UInt64 = 0) -> Int? {
        let count = images.count
        guard count > 0 else {
            return nil
        }
        switch mode {
        case .fixed:
            return 0
        case .random:
            return Int(seed % UInt64(count))
        case .rotate:
            // 负数也能落回合法区间，省得调用方自己防。
            return ((step % count) + count) % count
        }
    }

    func image(step: Int = 0, seed: UInt64 = 0) -> String? {
        guard let index = index(step: step, seed: seed) else {
            return nil
        }
        return images[index]
    }
}
