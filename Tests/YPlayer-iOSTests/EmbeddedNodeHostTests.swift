import CatVodNet
@testable import CatVodSource
import XCTest

/// 内嵌 Node（libnode）在**真实 iOS 运行时**里的端到端验证。
///
/// 这是 M16P4 里最关键的未知项：`dup2` 抓到的 stdout 是否真的包含就绪行。
/// 若这套探针不成立，失败信息里会带宿主最近输出 —— 便于直接切到备选方案
/// （`-r <preload>` 预载脚本 + bridge 回传就绪行）。
final class EmbeddedNodeHostTests: XCTestCase {
    /// 真的起一次宿主：下载 bundle → 启动 → 等就绪 → 取站点清单。
    ///
    /// 网络不可达时 **skip**（与 CI 的 js2p 契约作业同一策略：环境问题不该判成契约失败）。
    func testHostStartsAndReturnsSites() async throws {
        let scriptURL = try await Js2PBundleFixture.localIndexJS()

        let service = JS2PHostService(
            transport: URLSessionTransport(),
            scriptURL: scriptURL,
            readinessTimeout: 90
        )

        let snapshot: HostConfigSnapshot
        do {
            snapshot = try await service.sites()
        } catch {
            let output = await service.recentOutput(limit: 20)
            XCTFail("内嵌 Node 未能就绪：\(error)\n--- 宿主输出 ---\n\(output.joined(separator: "\n"))")
            return
        }

        XCTAssertGreaterThan(snapshot.sites.count, 0, "应至少解析出一个站点")
        let first = try XCTUnwrap(snapshot.sites.first)
        XCTAssertFalse(first.key.isEmpty)
        XCTAssertFalse(first.api.isEmpty, "站点 api 必须被补成绝对地址")
        XCTAssertTrue(first.isCatSpiderHTTP, "api 应形如 http://127.0.0.1:<port>/spider/...")

        // iOS 上 stop() 只断开日志采集（node_start 不可逆），这里只确认不崩。
        await service.stop()
    }
}

/// bundle 准备：下载 6.29 MB 的 `index.js`（文件名本身是自启动条件的一部分）。
enum Js2PBundleFixture {
    static let remoteURL = "https://9280.kstore.vip/ceshi/index.js"

    static func localIndexJS() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("js2p", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 必须是 index.js：bundle 的自启动条件要求 argv[1] 以它结尾。
        let target = directory.appendingPathComponent("index.js")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        guard let url = URL(string: remoteURL) else {
            throw XCTSkip("bundle 地址无法解析")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, data.count > 1_000_000 else {
                throw XCTSkip("bundle 下载异常：status=\(status) bytes=\(data.count)")
            }
            try data.write(to: target, options: .atomic)
            return target
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("bundle 不可达（\(error.localizedDescription)）—— 环境问题，跳过而非判失败")
        }
    }
}
