@testable import CatVodNode
import Foundation
import Testing

@Suite("内嵌 Node 启动参数（node_start 的 argv / env）")
struct NodeMobileLaunchPlanTests {
    private func configuration(
        script: String = "/tmp/index.js",
        port: Int = 9988
    ) -> NodeRuntimeConfiguration {
        NodeRuntimeConfiguration(
            scriptURL: URL(fileURLWithPath: script),
            preferredPort: port,
            readinessTimeout: 30
        )
    }

    @Test("argv = [node, <script>]，满足 bundle 自启动条件")
    func arguments() {
        let plan = NodeMobileLaunchPlan(configuration: configuration())
        #expect(plan.arguments == ["node", "/tmp/index.js"])
        #expect(plan.satisfiesAutoStartContract)
    }

    @Test("脚本名不是 index.js：标记为不满足自启动条件（不应启动）")
    func autoStartContract() {
        let plan = NodeMobileLaunchPlan(configuration: configuration(script: "/tmp/bundle.js"))
        #expect(plan.satisfiesAutoStartContract == false)
    }

    @Test("preload：插在 node 之后、脚本之前（-r）")
    func preload() {
        let plan = NodeMobileLaunchPlan(
            configuration: configuration(),
            preloadURL: URL(fileURLWithPath: "/tmp/preload.js")
        )
        #expect(plan.arguments == ["node", "-r", "/tmp/preload.js", "/tmp/index.js"])
    }

    @Test("环境变量：只注入端口/监听地址/日志开关，且不设 CATVOD_DISABLE_AUTOSTART")
    func environment() {
        let plan = NodeMobileLaunchPlan(configuration: configuration(port: 12345))
        #expect(plan.environment["DEV_HTTP_PORT"] == "12345")
        #expect(plan.environment["HOST"] == "127.0.0.1")
        #expect(plan.environment["NODE_ENV"] == "development")
        #expect(plan.environment["CATVOD_DISABLE_AUTOSTART"] == nil)
        // 其余环境变量继承进程，因此这里恰好三个键。
        #expect(plan.environment.count == 3)
    }

    @Test("withCArguments：argc 与最后一项 argv 正确（指针层面）")
    func cArguments() {
        let plan = NodeMobileLaunchPlan(configuration: configuration())
        let result: (Int32, String?) = plan.withCArguments { argc, argv in
            (argc, argv[Int(argc) - 1].map { String(cString: $0) })
        }
        #expect(result.0 == 2)
        #expect(result.1 == "/tmp/index.js")
    }
}
