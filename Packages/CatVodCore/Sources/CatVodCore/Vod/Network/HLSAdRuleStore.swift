import Foundation

/// 广告清理规则的**当前生效值**（M06d）。
///
/// 为什么要有这个小盒子：`/m3u8` 每个清单请求都要问一次「现在该用哪些规则」，
/// 而规则来自接口配置 —— 配置换了不该重启本机服务。
///
/// 线程安全：规则里装着 `NSRegularExpression`（非 `Sendable`），所以用 `NSLock` 包一层；
/// `@unchecked Sendable` 的成立条件与 `StorageFailureRecorder` 相同 —— **所有可变状态都在锁内访问**。
public final class HLSAdRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [HLSManifestCleaner.Rule]

    public init(rules: [HLSManifestCleaner.Rule] = []) {
        self.rules = rules
    }

    /// 换一批规则（配置重新加载时调用）。
    public func update(_ rules: [HLSManifestCleaner.Rule]) {
        lock.lock()
        defer { lock.unlock() }
        self.rules = rules
    }

    /// 当前规则（服务端每个请求读一次）。
    public var current: [HLSManifestCleaner.Rule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }
}
