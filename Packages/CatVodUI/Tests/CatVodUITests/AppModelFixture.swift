@testable import CatVodCore
import CatVodNet
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
    /// 隔离的存档名（`reopenedModel()` 用它读回同一份存档）。
    let suiteName: String
    /// 临时目录（缓存 / 数据库都在这里）。
    let directory: URL

    init(
        downloadTransport: HTTPTransport? = nil,
        tmdbTransport: HTTPTransport? = nil,
        danmakuTransport: HTTPTransport? = nil
    ) throws {
        suiteName = "yplayer-tests-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        model = AppModel(
            cacheDirectory: directory,
            defaults: defaults,
            downloadDirectory: Self.downloadDirectory(in: directory),
            downloadTransport: downloadTransport,
            storageURL: Self.storageURL(in: directory),
            tmdbTransport: tmdbTransport,
            danmakuTransport: danmakuTransport
        )
    }

    /// 下载目录放在夹具的临时目录里：测试之间不串味，也不会写进真机的 Application Support。
    static func downloadDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// 本地库也放进夹具目录（默认布局的缩小版：`Downloads` 旁边就是 `YPlayer.sqlite`）。
    ///
    /// 为什么必须注入：不注入时所有夹具都开真机 / runner 上的
    /// `Application Support/YPlayer/YPlayer.sqlite` —— 并行跑的用例共用一个库，
    /// 互相写对方的下载任务表（CI 首跑就栽在这）。
    static func storageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("YPlayer.sqlite")
    }

    /// 用**同一份存档**再起一个模型 —— 用来验「写进去的偏好，重开还在」。
    func reopenedModel() throws -> AppModel {
        try AppModel(
            cacheDirectory: directory,
            defaults: #require(UserDefaults(suiteName: suiteName)),
            downloadDirectory: Self.downloadDirectory(in: directory),
            storageURL: Self.storageURL(in: directory)
        )
    }

    /// 载入一份内联配置（不联网）。默认给一条能出分组的站点。
    func load(_ json: String = fixtureDefaultConfig) async {
        model.configURL = json
        await model.load()
    }

    /// 收尾：临时目录与隔离的 UserDefaults 都清掉，测试之间不串味。
    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

}

/// 夹具的默认内联配置。
///
/// **为什么放文件级**：`@MainActor` 类里的 `static let` 会被主 actor 隔离，而 `load(_:)` 的
/// **默认参数**是在非隔离上下文里求值的 —— 引用它就是那条
/// 「main actor-isolated static property … can not be referenced from a nonisolated context」
/// 警告（Swift 6 语言模式下是错误，M03P10 首验的日志里看到）。文件级的 `let` 没有这个问题。
///
/// 站点 api 用**完整回环地址**：`/spider/x` 这种相对写法会被可用性判定判成
/// 「无法识别的 Spider api」，站点全部不可见 —— 夹具要的是「真能用的站点」。
///
/// 站名形态是给用例用的：a 同时带方括号与竖线两种标签（`[主力]` + `4K`）；
/// b 的「首页」走**方括号** —— 关竖线规则的用例要求它不受竖线规则影响。
private let fixtureDefaultConfig = """
{"sites":[{"key":"a","name":"[主力]甲站|4K","type":3,"api":"http://127.0.0.1:9988/spider/a"},
          {"key":"b","name":"[首页]乙站","type":3,"api":"http://127.0.0.1:9988/spider/b"}]}
"""
