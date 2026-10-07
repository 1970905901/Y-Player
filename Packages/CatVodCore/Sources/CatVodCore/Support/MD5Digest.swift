import Foundation

public extension MD5 {
    /// 是否为 32 位十六进制摘要。
    ///
    /// 与参考实现 webhtv `NodeBundle.isMd5` 同款口径：`.md5` 端点的内容**必须**是这个形状才算校验值，
    /// 上游返回 HTML 错误页、空文件或半截内容时一律按「拿不到校验值」处理 ——
    /// 否则会把错误页当成摘要用来比对，判定结果毫无意义。
    static func isDigest(_ value: String) -> Bool {
        guard value.count == 32 else {
            return false
        }
        return value.allSatisfy(\.isHexDigit)
    }
}
