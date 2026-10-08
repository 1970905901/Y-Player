@testable import CatVodCore
import Testing

/// 接口地址的摘要键：本地偏好按接口分桶时用它，**不落明文地址**（地址里常带 token）。
///
/// 与 `HLSAdRuleState` 的源标识摘要同一口径（`MD5` 前 16 个十六进制字符），这里只是补一个 `cfg:` 前缀，
/// 让存档里一眼看得出「这是个接口标识」。
@Suite("接口地址摘要键")
struct ConfigIdentityTests {
    @Test("同一个地址永远同一个键")
    func stable() {
        let first = ConfigIdentity.key(for: "https://a.example.com/config?token=secret")
        let second = ConfigIdentity.key(for: "https://a.example.com/config?token=secret")

        #expect(first == second)
        #expect(first.hasPrefix("cfg:"))
        #expect(first.count == 4 + 16)
    }

    @Test("摘要里看不到地址与 token")
    func hidesURL() {
        let key = ConfigIdentity.key(for: "https://a.example.com/config?token=secret")

        #expect(!key.contains("example.com"))
        #expect(!key.contains("secret"))
    }

    @Test("不同地址不同键；空地址没有桶")
    func distinctAndEmpty() {
        #expect(ConfigIdentity.key(for: "https://a.example.com/config")
            != ConfigIdentity.key(for: "https://b.example.com/config"))
        #expect(ConfigIdentity.key(for: "").isEmpty)
        #expect(ConfigIdentity.key(for: "   ").isEmpty)
    }
}
