@testable import CatVodNode
import Foundation
import Testing

@Suite("Node 运行配置（env 契约）")
struct NodeRuntimeConfigurationTests {
    private func configuration(
        scriptName: String = "index.js",
        suppressLogging: Bool = true,
        extra: [String: String] = [:]
    ) -> NodeRuntimeConfiguration {
        NodeRuntimeConfiguration(
            scriptURL: URL(fileURLWithPath: "/tmp/yplayer-cache/\(scriptName)"),
            preferredPort: 9999,
            environment: extra,
            suppressBundleLogging: suppressLogging
        )
    }

    @Test("注入 DEV_HTTP_PORT / HOST / NODE_ENV")
    func injectsEnv() {
        let env = configuration().processEnvironment(base: [:])
        #expect(env["DEV_HTTP_PORT"] == "9999")
        #expect(env["HOST"] == "127.0.0.1")
        // 契约里是 `logger: NODE_ENV !== "development"`，所以「安静」= development
        #expect(env["NODE_ENV"] == "development")

        let verbose = configuration(suppressLogging: false).processEnvironment(base: [:])
        #expect(verbose["NODE_ENV"] == "production")
    }

    @Test("绝不保留 CATVOD_DISABLE_AUTOSTART（一旦为 1 就不自启动）")
    func removesAutostartBlocker() {
        let env = configuration().processEnvironment(base: [
            "CATVOD_DISABLE_AUTOSTART": "1",
            "PATH": "/usr/bin",
        ])
        #expect(env["CATVOD_DISABLE_AUTOSTART"] == nil)
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test("额外环境变量可覆盖固定项")
    func extraEnvOverrides() {
        let env = configuration(extra: ["HOST": "0.0.0.0", "PORT": "1234"]).processEnvironment(base: [:])
        #expect(env["HOST"] == "0.0.0.0")
        #expect(env["PORT"] == "1234")
    }

    @Test("自启动契约要求脚本名为 index.js（大小写不敏感）")
    func autoStartContract() {
        #expect(configuration().satisfiesAutoStartContract)
        #expect(configuration(scriptName: "Index.JS").satisfiesAutoStartContract)
        #expect(!configuration(scriptName: "index.mjs").satisfiesAutoStartContract)
        #expect(!configuration(scriptName: "bundle.js").satisfiesAutoStartContract)
    }
}
