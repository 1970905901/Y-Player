import Foundation

/// 弹幕源的选取（M09e）。
///
/// 上游 `VodPlaybackMedia.searchDanmaku` 里这个判定是关键一环（源码已核）：
///
/// ```java
/// if (DanmakuSetting.isSpiderFirst() && !result.getDanmaku().isEmpty()) add.accept(danmaku);
/// else set.accept(danmaku);
/// ```
///
/// 也就是说：**站点结果里自带的弹幕源优先**，没有才用 API 搜索出来的。
/// 这不是细节 —— 站点自己给的源通常跟它自己的片源/集名对得上，而 API 搜索是按片名猜的。
///
/// 抽成纯函数是因为它**不需要网络**：选择逻辑能单独钉住，
/// 而真正下载弹幕文件那一步在测试里跑不了（离线）。
public enum DanmakuSourceSelection {
    /// 选中的源 + 它从哪来。
    public struct Selection: Sendable, Equatable {
        public var source: DanmakuSource
        /// `true` = 站点结果自带（上游 `isSpiderFirst` 指的就是它）。
        public var isFromResult: Bool

        public init(source: DanmakuSource, isFromResult: Bool) {
            self.source = source
            self.isFromResult = isFromResult
        }
    }

    /// 优先结果自带，其次 API 搜索；都没有则 `nil`。
    ///
    /// 两边的空地址项都会被丢掉（``DanmakuSource`` 那边有同名的过滤口径）——
    /// 列了语言却没给地址的项，取来也下不到东西。
    public static func preferred(result: [DanmakuSource], api: [DanmakuSource]) -> Selection? {
        if let embedded = firstUsable(result) {
            return Selection(source: embedded, isFromResult: true)
        }
        if let searched = firstUsable(api) {
            return Selection(source: searched, isFromResult: false)
        }
        return nil
    }

    /// 候选里第一条能用的（`url` 非空）。``preferred(result:api:)`` 用的就是它；
    /// M03P25 的「回到自动」也走它 —— 候选已经按「站点自带在前」拼好，直接取第一条即可。
    public static func firstUsable(_ sources: [DanmakuSource]) -> DanmakuSource? {
        sources.first { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
