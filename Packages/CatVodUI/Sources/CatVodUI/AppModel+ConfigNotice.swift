import CatVodCore
import Foundation

/// 配置自带的公告与图标（`SourceConfig.notice` / `.logo`）。
///
/// 为什么单开一片：这两个字段**一直是解析进来就丢**的（矩阵里那行 ⚠️ 就是这个）——
/// 公告是配置作者给用户的话（「本站已更换域名」「旧接口将于 X 日失效」），
/// 说丢就丢，用户完全不知道。
extension AppModel {
    /// 当前配置的公告原文；空白等于没有。
    var configNotice: String {
        (state.loadedSource?.config.notice ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前配置的图标地址；空白等于没有。
    var configLogo: String {
        (state.loadedSource?.config.logo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **还没被关掉**的公告（发现页那条横幅读它）；关过同一条就不再出现。
    ///
    /// 判据就是「文字与关掉的那条是否相同」—— 不做指纹、不做 TTL：
    /// 公告的作用就是让人看见，同一句话不该反复弹；配置换了公告（文字变了）自然会再出现。
    var pendingConfigNotice: String? {
        let notice = configNotice
        guard !notice.isEmpty else {
            return nil
        }
        return notice == dismissedConfigNotice ? nil : notice
    }

    /// 关掉当前这条公告（只记文字；接口管理页里仍然查得到全文）。
    func dismissConfigNotice() {
        let notice = configNotice
        guard !notice.isEmpty else {
            return
        }
        dismissedConfigNotice = notice
    }
}
