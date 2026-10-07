import CatVodCore
import Foundation

/// 列表补图：部分源（`type 0/1/2`）在首页/分类接口不返回封面，需要再按 `ids` 批量取图。
///
/// 协议对照：`ApiURLBuilder.pictureRequest`（`ac=detail&ids=…`，逗号连接，仅 0/1/2 适用）。
///
/// 策略：**best-effort，不打断列表展示**。
/// - 只在缺图比例达到阈值时才多打一次接口（少量缺图不值得）；
/// - 补图失败、或站点不支持（`type=3/4`）时原样返回原结果，不报错、不阻塞 UI。
public struct PictureFiller: Sendable {
    public var client: CMSClient
    /// 触发补图的最小缺图比例（0...1）。默认 0.5。
    public var missingRatioThreshold: Double

    public init(client: CMSClient, missingRatioThreshold: Double = 0.5) {
        self.client = client
        self.missingRatioThreshold = missingRatioThreshold
    }

    /// 该站点 + 该结果是否需要补图。
    public func needsFilling(site: Site, result: SpiderResult) -> Bool {
        guard !result.list.isEmpty else {
            return false
        }
        // 上游的补图接口只覆盖 0/1/2；type=4 的 api 是 ext 远程文本，type=3 走 Spider 通道。
        switch site.kind {
        case .xmlApi, .jsonApi, .jsonApiCompat:
            break
        default:
            return false
        }
        // 注意：不用 `count(where:)`（Swift 6 标准库新增，需要 iOS 18/macOS 15 运行时），本项目最低 iOS 15。
        let missing = result.list.filter { $0.vodPic.isEmpty }.count
        return Double(missing) / Double(result.list.count) >= missingRatioThreshold
    }

    /// 补图；无需补图、失败或无有效返回时**原样返回**。
    public func fill(site: Site, result: SpiderResult) async -> SpiderResult {
        guard needsFilling(site: site, result: result) else {
            return result
        }
        guard let filled = try? await client.fillingPictures(site: site, result: result) else {
            return result
        }
        return filled
    }
}
