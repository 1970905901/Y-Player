@testable import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// AppModel 的**集成测试夹具**（M08e）：用内联配置把一个完整的 AppModel 跑起来 —— 不联网、不碰真存档。
///
/// 为什么专门做它：M06l / M08c 那两笔都记着「接线没有单测，因为测试里构造不出完整 AppModel」。
/// 这个借口其实站不住 ——
/// - `AppModel.init(cacheDirectory:defaults:)` 本来就支持注入临时目录与隔离的 `UserDefaults`；
/// - 内联配置（`{…}`）由 `ConfigLocator` 直接当本地配置处理，**不需要网络**。
///
/// 于是「只能靠调用点审查」的那类胶水代码（改名、规则开关、站点分组、跳过广告统计）现在能真的跑起来验。
@MainActor
final class AppModelFixture {
    let model: AppModel
    private let suiteName: String
    private let directory: URL

    init() throws {
        suiteName = "yplayer-tests-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        model = AppModel(cacheDirectory: directory, defaults: defaults)
    }

    /// 载入一份内联配置（不联网）。默认给一条能出分组的站点。
    func load(_ json: String = AppModelFixture.defaultConfig) async {
        model.configURL = json
        await model.load()
    }

    /// 收尾：临时目录与隔离的 UserDefaults 都清掉，测试之间不串味。
    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    static let defaultConfig = """
    {"sites":[{"key":"a","name":"[主力]甲站|4K","type":3,"api":"/spider/a"},
              {"key":"b","name":"乙站|首页","type":3,"api":"/spider/b"}]}
    """
}
