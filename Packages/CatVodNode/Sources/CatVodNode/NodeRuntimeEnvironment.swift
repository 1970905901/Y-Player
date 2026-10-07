import Foundation

/// 运行时的**平台选择**：macOS 走进程，iOS 走随包内嵌的 libnode。
///
/// 集中在一处的理由：上层（``JS2PHostService``）只该问「有没有运行时」与「给我一个」，
/// 不该让 `#if os(...)` / `#if canImport(...)` 散落到业务代码里。
public enum NodeRuntimeEnvironment {
    /// 当前构建是否有可用的 Node 运行时。
    ///
    /// - iOS：链接了 `NodeMobile.framework`（即 `canImport(NodeMobile)` 成立）就视为可用；
    /// - macOS：需要能定位到 `node` 可执行文件（随包 `Resources/node/node`、`YPLAYER_NODE`、Homebrew、系统路径）。
    public static var isRuntimeAvailable: Bool {
        #if canImport(NodeMobile)
        return true
        #elseif os(macOS)
        return NodeRuntimeAdapter.locateNodeExecutable() != nil
        #else
        return false
        #endif
    }

    /// 「不可用」的具体原因，供界面直接展示（不允许只说「不可用」）。
    public static var unavailableReason: String {
        #if canImport(NodeMobile)
        return "已链接 NodeMobile（不应出现此提示）"
        #elseif os(macOS)
        return "未找到 node 可执行文件（随包 Resources/node/node、环境变量 YPLAYER_NODE，或 Homebrew/系统路径）"
        #else
        return """
        当前构建没有内嵌 Node 运行时：iOS 需要随包 NodeMobile.xcframework。\
        先运行 `python Scripts/fetch_nodejs_mobile.py` 取产物，再重新生成工程（见 docs/任务记录/M16P4-iOS内嵌libnode.md）。
        """
        #endif
    }

    /// 按平台构造运行时。
    public static func makeRuntime(configuration: NodeRuntimeConfiguration) -> any NodeRuntimeLaunching {
        #if canImport(NodeMobile)
        return NodeMobileRuntime(configuration: configuration)
        #else
        return NodeRuntimeAdapter(configuration: configuration)
        #endif
    }
}
