import CatVodCore
import CatVodNet
import CatVodPlayer
import CatVodSource
import Combine
import Foundation
import SwiftUI

/// 应用主状态。
///
/// 职责：持有「配置来源 → 站点清单 → 各站点客户端」的状态，并做展示层需要的一切决策：
/// 哪些站点可用、哪些不可用及原因、当前播放内核（含降级原因）。
///
/// 说明：iOS 15 / macOS 13 下限下使用 `ObservableObject`（`@Observable` 需 iOS 17+，
/// 按 `docs/UI 规范.md` 不得为统一观感而抬高下限）。
@MainActor
public final class AppModel: ObservableObject {
    /// 配置加载状态。
    public enum LoadState: Sendable {
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

    // MARK: - 持久化键

    private enum StorageKey {
        static let configURL = "yplayer.configURL"
        static let preferredEngine = "yplayer.preferredEngine"
    }

    // MARK: - 输出状态

    @Published public private(set) var state: LoadState = .idle
    @Published public var configURL: String {
        didSet {
            UserDefaults.standard.set(configURL, forKey: StorageKey.configURL)
        }
    }
    @Published public var preferredEngine: PlayerEngineKind {
        didSet {
            UserDefaults.standard.set(preferredEngine.rawValue, forKey: StorageKey.preferredEngine)
        }
    }
    @Published public private(set) var playbackNotice: String = ""

    // MARK: - 依赖

    private let cacheDirectory: URL
    private let sessionTransport: URLSessionTransport

    public init(cacheDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = base
        self.sessionTransport = URLSessionTransport()

        self.configURL = defaults.string(forKey: StorageKey.configURL) ?? ""
        let storedEngine = defaults.string(forKey: StorageKey.preferredEngine)
        self.preferredEngine = storedEngine.flatMap(PlayerEngineKind.init(rawValue:)) ?? .system
        refreshPlaybackNotice()
    }

    // MARK: - 配置

    /// 当前配置里可用的站点（已剔除隐藏与不可用项）。
    public var sites: [Site] {
        state.loadedSource?.config.usableSites ?? []
    }

    /// 全部站点（含不可用，界面需要展示原因）。
    public var allSites: [Site] {
        state.loadedSource?.config.visibleSites ?? []
    }

    /// 配置告警（含站点不可用原因、离线回退提示）。
    public var warnings: [String] {
        state.loadedSource?.warnings ?? []
    }

    public var loadedKind: LoadedSource.Kind? {
        state.loadedSource?.kind
    }

    /// 加载配置。
    public func load(forceRefresh: Bool = false) async {
        let target = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            state = .failed("请先填写配置地址（支持猫源 JSON 或 js2p 的 index.js）")
            return
        }
        state = .loading

        let transport = transportForConfiguration()
        let repository = SourceRepository(transport: transport, cacheDirectory: cacheDirectory)
        do {
            let loaded = try await repository.load(configURL: target, forceRefresh: forceRefresh)
            state = .loaded(loaded)
        } catch let error as CatVodError {
            state = .failed(error.errorDescription ?? "加载失败")
        } catch {
            state = .failed(error.localizedDescription)
        }
        refreshPlaybackNotice()
    }

    /// 为站点请求构造传输层：把配置里的 `headers` 与 `ads` 规则带进去。
    public func transportForConfiguration() -> HTTPTransport {
        guard let config = state.loadedSource?.config else {
            return sessionTransport
        }
        return URLSessionTransport(configuration: URLSessionTransport.Configuration(config: config))
    }

    /// 站点客户端（CMS 通道）。
    public func makeCMSClient() -> CMSClient {
        CMSClient(transport: transportForConfiguration())
    }

    /// js2p 通道客户端：本地 Node 服务就绪后传入 baseURL（M1.6 落地）。
    public func makeCatSpiderClient(baseURL: URL) -> CatSpiderHTTPClient? {
        CatSpiderHTTPClient(
            baseURL: baseURL,
            transport: transportForConfiguration()
        )
    }

    /// 当前播放内核选择结果（含降级原因）。
    public func playbackSelection() -> PlayerCoordinator.Selection {
        PlayerCoordinator().select(preferred: preferredEngine)
    }

    private func refreshPlaybackNotice() {
        if case .javaScript = state.loadedSource?.kind {
            playbackNotice = "当前是 JS 源（js2p）：站点清单需等内嵌 Node 服务就绪后加载（M1.6）"
            return
        }
        let selection = PlayerCoordinator().select(preferred: preferredEngine)
        playbackNotice = selection.didFallback ? selection.reason : ""
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("YPlayer/Sources", isDirectory: true)
    }
}
