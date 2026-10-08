import Foundation

/// 「组名里的 `_` 不当密码」的本地覆盖（上游 `bean/Live.java` 的 `pass` 字段 + `pass(boolean)`）。
///
/// 背景：源里把加密分组写成 `分组名_密码`，解析时按第一个 `_` 拆成「名字 + 密码」，
/// 于是这一组变成**加密分组**（界面默认不显示，要输密码）。
/// 有些源的组名里本来就有 `_`（例如 `央视_高清`）—— 那串东西其实是名字的一部分，
/// 拆开之后既看不见、也永远解锁不了。上游为此留了 `pass`：为 true 时**不拆**。
///
/// 这里只做「套用覆盖」这一件纯事：`nil` = 不覆盖（用源自己的字段）。
public extension LiveSource {
    /// 套用覆盖后、送进解析器的源（`pass` 是解析期字段，必须在 `LivePlaylistParser` 之前套）。
    ///
    /// 传 `nil` 表示沿用源自己的 `pass`；`true` / `false` 是本地覆盖的两个方向
    /// （源里写了 `pass: true`、用户想关掉也拨得回去，所以是显式布尔值而不是「打开过的集合」）。
    func applyingGroupPass(_ enabled: Bool?) -> LiveSource {
        var result = self
        if let enabled {
            result.pass = enabled
        }
        return result
    }
}
