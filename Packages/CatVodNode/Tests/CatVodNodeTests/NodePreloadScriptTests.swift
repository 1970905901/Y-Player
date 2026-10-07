@testable import CatVodNode
import Foundation
import Testing

/// 预载脚本是「内嵌 node 崩了还能留下证据」的唯一手段，因此它的关键行为必须被钉住。
@Suite("内嵌 Node 预载脚本")
struct NodePreloadScriptTests {
    @Test("核心职责：拦截致命退出，而不是让宿主 App 一起死掉")
    func blocksFatalExits() {
        let markers = [
            "process.exit = function",
            "process.on('uncaughtException'",
            "process.on('unhandledRejection'",
            "BLOCKED process.exit",
        ]
        for marker in markers {
            #expect(NodePreloadScript.source.contains(marker), "预载缺少关键片段：\(marker)")
        }
    }

    @Test("日志路径由 YPLAYER_NODE_LOG 指定，且用追加写（进程死后可回读）")
    func writesToLogFile() {
        #expect(NodePreloadScript.logEnvironmentKey == "YPLAYER_NODE_LOG")
        #expect(NodePreloadScript.source.contains(NodePreloadScript.logEnvironmentKey))
        #expect(NodePreloadScript.source.contains("appendFileSync"))
    }

    @Test("探测不支持的核心模块 —— 即 M16P4 第 4 项（child_process / worker_threads）")
    func probesCoreModules() {
        #expect(NodePreloadScript.source.contains("child_process"))
        #expect(NodePreloadScript.source.contains("worker_threads"))
        #expect(NodePreloadScript.source.contains("module MISSING"))
    }

    @Test("物化到临时目录：内容可读回，且同内容不重复写")
    func materializeIsIdempotent() throws {
        let url = try NodePreloadScript.materialize()
        #expect(url.lastPathComponent == NodePreloadScript.fileName)
        #expect(url.deletingLastPathComponent().lastPathComponent == "yplayer-node")
        #expect(try String(contentsOf: url, encoding: .utf8) == NodePreloadScript.source)

        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let again = try NodePreloadScript.materialize()
        let second = try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date
        #expect(first == second, "内容一致时不应重写文件")
    }

    @Test("落盘日志与预载脚本同目录")
    func logLivesNextToScript() {
        let directory = NodePreloadScript.stagingDirectory()
        #expect(NodePreloadScript.logURL().deletingLastPathComponent() == directory)
        #expect(NodePreloadScript.logURL().lastPathComponent == NodePreloadScript.logFileName)
    }
}

@Suite("启动参数：预载注入不破坏自启动条件")
struct NodePreloadLaunchPlanTests {
    private func configuration() -> NodeRuntimeConfiguration {
        NodeRuntimeConfiguration(scriptURL: URL(fileURLWithPath: "/tmp/bundle/index.js"))
    }

    @Test("预载插在脚本之前：argv[1] 仍以 index.js 结尾")
    func keepsAutoStartContract() {
        let plan = NodeMobileLaunchPlan(
            configuration: configuration(),
            preloadURL: URL(fileURLWithPath: "/tmp/yplayer-node/yplayer-node-preload.js")
        )
        #expect(
            plan.arguments == [
                "node",
                "-r",
                "/tmp/yplayer-node/yplayer-node-preload.js",
                "/tmp/bundle/index.js",
            ]
        )
        #expect(plan.satisfiesAutoStartContract)
    }

    @Test("落盘日志路径随环境注入，且绝不打开 CATVOD_DISABLE_AUTOSTART")
    func injectsLogPath() {
        var configuration = configuration()
        configuration.environment[NodePreloadScript.logEnvironmentKey] = "/tmp/yplayer-node/yplayer-node.log"
        let plan = NodeMobileLaunchPlan(configuration: configuration)
        #expect(plan.environment[NodePreloadScript.logEnvironmentKey] == "/tmp/yplayer-node/yplayer-node.log")
        #expect(plan.environment["DEV_HTTP_PORT"] == "9988")
        #expect(plan.environment["CATVOD_DISABLE_AUTOSTART"] == nil)
    }
}
