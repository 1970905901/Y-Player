import CatVodSource
import Foundation

extension AppModel {
    /// TMDB 配置（Emby 视图那一层）：**读写都走注入的 `defaults`**，与其它设置同一条路。
    ///
    /// 做成计算属性是有意的：**不用动 `init` 里那一串装载代码** —— 谁读谁从盘上取，
    /// 谁写谁立刻落盘（「用户动作即落盘」的口径不变）。
    ///
    /// 全空时把键**删掉**而不是写一个空串：盘上不留「有键但没值」这种需要人肉眼判断的状态。
    var tmdbConfig: TMDBConfig {
        get {
            TMDBConfig(storageString: defaults.string(forKey: Self.tmdbConfigDefaultsKey) ?? "")
        }
        set {
            let encoded = newValue.storageString
            if encoded.replacingOccurrences(of: "|", with: "").isEmpty {
                defaults.removeObject(forKey: Self.tmdbConfigDefaultsKey)
            } else {
                defaults.set(encoded, forKey: Self.tmdbConfigDefaultsKey)
            }
        }
    }

    /// 「这一层能不能用」：只是 `TMDBConfig.isConfigured` 的透传，放在这里让界面少认识一个类型。
    var isTMDBConfigured: Bool {
        tmdbConfig.isConfigured
    }

    /// 取图模式（固定 / 随机 / 轮播）：**顶部与选集卡片共用同一套**（见 ``PosterPicker``）。
    ///
    /// 与其它偏好同一条路：读写在注入的 `defaults` 上，用户改一次落一次盘。
    /// 值不认识就回落 `.fixed`（旧版本写进去的值、或手改过的串，都不该让界面空着）。
    var tmdbPosterMode: PosterMode {
        get {
            defaults.string(forKey: Self.tmdbPosterModeDefaultsKey)
                .flatMap(PosterMode.init(rawValue:)) ?? .fixed
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.tmdbPosterModeDefaultsKey)
        }
    }

    private static let tmdbConfigDefaultsKey = "tmdb.config"
    private static let tmdbPosterModeDefaultsKey = "tmdb.posterMode"
}
