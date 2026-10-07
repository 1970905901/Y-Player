import Foundation

/// 内嵌 Node（libnode）启动参数的**纯计算**部分。
///
/// 为什么单独抽出来：真正调 `node_start` 的那段只在「iOS + 随包带 `NodeMobile.framework`」时才存在，
/// 而「argv 怎么拼、要注入哪些环境变量」是平台无关的规则 —— 抽出来就能在**任何平台**单测
/// （CI 的 macOS runner 也能跑到，不必等真机）。
///
/// 约定与参考实现一致（`nodejs-mobile-cordova` 的 `CDVNodeJS.mm` + `NodeJSRunner.mm`）：
/// - `argv[0]` 固定为 `"node"`；
/// - 末尾是脚本路径，于是 `process.argv[1]` 必须以 `index.js` 结尾 —— 这正是 bundle 的自启动条件；
/// - 可选 `-r <preload>`：在 bundle 之前先加载一段补丁脚本（预留能力，当前不启用）。
public struct NodeMobileLaunchPlan: Sendable, Equatable {
    /// 传给 `node_start(argc, argv)` 的参数列表。
    public let arguments: [String]
    /// 启动前需要 `setenv` 的键值（其余环境变量继承进程，不在这里覆盖）。
    public let environment: [String: String]
    /// 脚本名是否满足 bundle 的自启动条件；为 false 时**不应该**启动（必然不会监听）。
    public let satisfiesAutoStartContract: Bool

    public init(configuration: NodeRuntimeConfiguration, preloadURL: URL? = nil) {
        var arguments = ["node"]
        if let preloadURL {
            arguments.append(contentsOf: ["-r", preloadURL.path])
        }
        arguments.append(configuration.scriptURL.path)
        self.arguments = arguments
        // base 传空字典：只取「我们要注入」的键，调用方逐个 setenv。
        environment = configuration.processEnvironment(base: [:])
        satisfiesAutoStartContract = configuration.satisfiesAutoStartContract
    }

    /// 汇成 `node_start` 需要的 C 形式（argv 需要连续内存 + 结尾 NULL）。
    ///
    /// 供 UIKit 侧调用；单测不碰指针，只验证 ``arguments``/``environment``。
    public func withCArguments<R>(_ body: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var cArguments = arguments.map { strdup($0) }
        defer {
            for pointer in cArguments {
                free(pointer)
            }
        }
        cArguments.append(nil)
        return cArguments.withUnsafeMutableBufferPointer { buffer in
            body(Int32(arguments.count), buffer.baseAddress!)
        }
    }
}
