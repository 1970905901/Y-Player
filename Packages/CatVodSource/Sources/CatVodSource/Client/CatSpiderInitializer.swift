import CatVodCore
import Foundation

/// js2p 站点的**一次性** `POST /init`。
///
/// 为什么需要它（参考实现给的答案，不是猜的）：`CatSpider.java` 里
/// ```java
/// @Override public void init(Context context, String extend) { post("/init", new JsonObject()); }
/// ```
/// 宿主框架在**建 spider 实例时**先调 `init`，之后才轮到 `home/category/detail/search/play`。
/// bundle 侧也是按这个契约注册的（`x.post("/init", t.init?.bind(t) || $zt)`，
/// 没有实现的 spider 走空实现），实测 `POST /spider/wogg/init` 会返回
/// `{"siteUrl":"https://www.wogg.net"}` —— 也就是说**有实现的站点确实在这里做准备**。
///
/// 我们之前只在单测里调过 `initialize()`，应用流程一次都没调：对「init 是空实现」的站点
/// 看不出来，对真有实现的站点就是缺了一步。
///
/// 语义：
/// - **按 `api` 全路径记忆**（`http://127.0.0.1:<port>/spider/<key>[/<type>]`）——
///   与参考实现「按 api 建 spider 实例」一致；同一 spider 的不同 `type` 入口各 init 一次；
/// - **只发一次**，包括**失败**的情况（对应参考实现的「实例只 init 一次」），
///   不因一次失败就在每个动作前重试；
/// - **失败不阻断**后续动作：参考实现的 `post()` 在非 200 时只记日志、返回空串，
///   我们保持同样行为（动作自己会把可读错误抛给界面），但把原因记下来供诊断；
/// - 并发调用**共享同一次请求**：第二个调用会等第一个完成，而不是各自再发一次。
public actor CatSpiderInitializer {
    /// 每个站点一次；保存 Task 而不是 Bool，这样并发调用能等到同一个结果。
    private var attempts: [String: Task<String?, Never>] = [:]
    private var failures: [String: String] = [:]

    public init() { }

    /// 确保该站点已 init（同一站点只发一次）。
    ///
    /// - Parameter client: 目标站点的 CatSpider 客户端；`baseURL` 用作记忆键。
    public func ensureInitialized(_ client: CatSpiderHTTPClient) async {
        let key = client.baseURL.absoluteString
        if let existing = attempts[key] {
            _ = await existing.value
            return
        }
        let task = Task<String?, Never> { [client] in
            do {
                _ = try await client.initialize()
                return nil
            } catch {
                return "\(error)"
            }
        }
        attempts[key] = task
        if let reason = await task.value {
            failures[key] = reason
        }
    }

    /// 诊断：该站点 init 失败的原因；成功或未 init 的站点返回 nil。
    public func failureNote(forBaseURL baseURL: String) -> String? {
        failures[baseURL]
    }

    /// 诊断：init 失败的站点数（界面/日志用一行数字即可）。
    public func failureCount() -> Int {
        failures.count
    }
}
