import CatVodSource
import Foundation

/// 「这一部片子该显示哪张图」—— 把三块零件合起来的那一处（M11）。
///
/// `TMDBConfig` 负责改写地址（过图片代理）、`TMDBClient.backdrops` 负责拿图集、
/// ``PosterPicker`` 负责按模式挑一张 —— 但**没有任何一处把它们合起来用**。
/// 这个类型就是那一处：给元信息 + 图集 + 配置 + 模式，出「现在该显示的那张图」。
///
/// 取图优先级（顺序即优先级，去重后保留首个）：
/// 1. **图集**（`/images` 的 backdrops）—— 多张，正是「随机 / 轮播」要的；
/// 2. 元信息里的主**背景图**；
/// 3. 元信息里的主**海报**（竖幅，图集为空时的兜底）。
///
/// 全空时 `image(step:seed:)` 给 `nil` —— 界面据此显示占位，不是空白。
/// 竖幅海报只在**宽幅两条来源都空**时出现 —— 横滑轮播里混进竖图会跳比例。
struct TMDBPosterSet: Sendable {
    /// 已改写、已去重、按优先级排好的图片地址。
    let urls: [String]
    let mode: PosterMode

    init(metadata: TMDBMetadata, backdrops: [String], config: TMDBConfig, mode: PosterMode) {
        var seen = Set<String>()
        var resolved: [String] = []
        // 宽幅两级（图集 → 主背景）按优先级依次尝试；统一走 config 改写
        // （图片代理就在这里生效一次，别在外面又拼一遍）。
        let candidates = backdrops + [metadata.backdropPath]
        for candidate in candidates {
            guard let url = config.imageURL(candidate)?.absoluteString, !seen.contains(url) else {
                continue
            }
            seen.insert(url)
            resolved.append(url)
        }
        // 竖幅海报只在**宽幅来源全空**时兜底：横滑轮播里混进竖图会跳比例。
        if resolved.isEmpty, let url = config.imageURL(metadata.posterPath)?.absoluteString {
            resolved.append(url)
        }
        urls = resolved
        self.mode = mode
    }

    var isEmpty: Bool { urls.isEmpty }

    private var picker: PosterPicker {
        PosterPicker(images: urls, mode: mode)
    }

    /// 当前该显示的那张。`seed` 只在随机模式生效，**进页面定一次**（见 ``PosterPicker``）。
    func image(step: Int = 0, seed: UInt64 = 0) -> String? {
        picker.image(step: step, seed: seed)
    }
}
