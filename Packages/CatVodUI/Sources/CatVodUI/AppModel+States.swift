import CatVodSource

// 两个「加载状态」类型从类体里搬出来（M06f 遗留清单第 3 条）：`@Published` 存储属性必须在类体里，
// 而类型声明放进扩展就够了 —— 类体因此只剩「状态 + 存储 + init」，`type_body_length` 留出余量。
//
// 路径不变：嵌套类型写在扩展里仍然属于 `AppModel`，所以 `AppModel.LoadState` / `AppModel.LiveState`
// 这些写法一个都不用改。

public extension AppModel {
    /// 配置加载状态。
    enum LoadState: Sendable {
        case idle
        case loading
        case loaded(LoadedSource)
        case failed(String)

        public var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }

        public var loadedSource: LoadedSource? {
            if case let .loaded(source) = self {
                return source
            }
            return nil
        }

        public var failureReason: String? {
            if case let .failed(reason) = self {
                return reason
            }
            return nil
        }
    }
}

public extension AppModel {
    /// 直播清单的加载状态（写法与 ``LoadState`` 一致：界面据此显示加载中 / 失败原因）。
    enum LiveState: Sendable {
        case idle
        case loading
        case loaded(LiveSource)
        case failed(String)

        public var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }

        public var loadedSource: LiveSource? {
            if case let .loaded(source) = self {
                return source
            }
            return nil
        }

        public var failureReason: String? {
            if case let .failed(reason) = self {
                return reason
            }
            return nil
        }
    }
}
