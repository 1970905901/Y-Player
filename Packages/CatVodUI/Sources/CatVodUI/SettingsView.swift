import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

/// 设置页（参考图 1 的「设置」Tab）。
///
/// 分区与顺序对齐参考图：源地址 / 首页 / 播放 / 数据（参考图里还有「iCloud 同步」——
/// **不做就不摆**：2026-10-10 拍板跨设备同步不做，那一区整块删掉，连标题也不留）。
/// 每一项都是**导航行**，点进去才是具体设置页 —— 与系统设置一致的原生形态。
///
/// 诚实原则（`docs/UI 规范.md` + `docs/任务记录/M02P11-设置页与追剧页.md`）：
/// 有真实数据可接的项就接真实数据（源地址、展示方式、内核/解码、解析器清单、缓存、宿主日志）；
/// **已决定不做**的项（iCloud 同步，2026-10-10 拍板：没有开发者账号）**整块不出现** ——
/// 不摆灰开关、不摆占位说明、也不留那句「属后续里程碑」（占位本身就是在许愿）。
@MainActor
public struct SettingsView: View {
    @ObservedObject private var model: AppModel
    /// 本 Tab 的沉浸页登记簿（下载好的文件直接播时收起底部 Tab 栏）。
    @EnvironmentObject private var immersiveTabBar: ImmersiveTabBarState

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        List {
            sourceSection
            homeSection
            playbackSection
            siteGroupSection
            dataSection
            aboutSection
        }
        .adaptiveListStyle()
        .navigationTitle("设置")
        .adaptiveTabBarHidden(immersiveTabBar.isActive)
    }

    // MARK: - 源地址

    /// 源地址：大字段名 + 一行地址小字（对齐参考图的第一块）。
    ///
    /// 点进去是原来的 ``InterfaceManagementView``（粘贴地址 / 加载 / 强制刷新 / 站点清单 /
    /// 宿主状态 / 接口缓存），也就是说「接口管理」这个功能没有消失，只是换了入口位置。
    private var sourceSection: some View {
        Section("源地址") {
            NavigationLink {
                InterfaceManagementView(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                    Text(sourceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// 源名称。
    ///
    /// 猫源配置里没有「配置名」字段（只有 `logo`/`notice` 和站点名），所以这里**不编造名字**：
    /// 有远端地址就用它的 host，JS 源写「JS 源（js2p）」，内联配置写「内联配置」。
    private var sourceName: String {
        guard !trimmedConfigURL.isEmpty else {
            return "未配置源地址"
        }
        if let host = model.state.loadedSource?.originURL?.host, !host.isEmpty {
            return host
        }
        return model.loadedKind == .javaScript ? "JS 源（js2p）" : "内联配置"
    }

    /// 地址（或未配置 / 加载失败的说明）。
    private var sourceSummary: String {
        if let reason = model.state.failureReason {
            return "加载失败：\(reason)"
        }
        guard !trimmedConfigURL.isEmpty else {
            return "点这里粘贴猫源 JSON 配置地址，或 js2p 的 index.js 地址"
        }
        if model.state.isLoading {
            return "加载中…"
        }
        if trimmedConfigURL.hasPrefix("{") {
            return "内联 JSON 配置"
        }
        return trimmedConfigURL
    }

    private var trimmedConfigURL: String {
        model.configURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 站点分组规则

    /// 站点分组：分组条（抽标签）与它的规则从哪来、怎么关。
    ///
    /// 放在「播放」之后、有独立页面（``SiteGroupRulesView``）：分组条只在站点面板里看得见，
    /// 但「为什么这个分组没了」的答案在规则里 —— 两者挨着放，找起来不用跳。
    private var siteGroupSection: some View {
        Section("站点分组") {
            NavigationLink {
                SiteGroupRulesView(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("分组规则")
                    Text(siteGroupSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// 一行摘要：现在有几条规则在生效、当前接口给了几条、自己加了几条。
    private var siteGroupSummary: String {
        let entries = model.siteGroupRuleEntries
        let enabled = entries.filter(\.isEnabled).count
        let userCount = entries.filter { $0.rule.source == GroupRule.sourceUser }.count
        let interfaceCount = entries.filter { $0.rule.source == GroupRule.sourceInterface }.count
        return "已启用 \(enabled) / \(entries.count) 条；接口给 \(interfaceCount) 条，自建 \(userCount) 条"
    }

    // MARK: - 首页

    private var homeSection: some View {
        Section("首页") {
            InfoRow(title: "首页内容", value: "剧集列表")
            Picker("展示方式", selection: $model.homeLayout) {
                ForEach(HomeLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            Text("首页内容当前固定为剧集列表（分类 + 筛选 + 分页，两种展示方式共用同一份数据）；自定义首页区块不在本里程碑。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section("播放") {
            NavigationLink {
                SettingsPlayerView(model: model)
            } label: {
                InfoRow(title: "播放器", value: model.preferredEngine.displayName)
            }
            NavigationLink {
                SettingsPlaybackPageView(model: model)
            } label: {
                // 值给当前排布：这行点进去是「显示视图 + 自动播放」。原来写死的「系统原生」
                // 是 M02 那个「现状说明页」的残留 —— 播放器类型已经由上一行「播放器」说了。
                InfoRow(title: "播放页", value: model.playbackPageLayout.displayName)
            }
            NavigationLink {
                SettingsDanmakuAPIView(model: model)
            } label: {
                InfoRow(title: "弹幕 API", value: parserSummary)
            }
            NavigationLink {
                SettingsDanmakuDisplayView(model: model)
            } label: {
                InfoRow(title: "弹幕显示", value: danmakuDisplaySummary)
            }
            NavigationLink {
                SettingsSubtitleDisplayView(model: model)
            } label: {
                InfoRow(title: "字幕显示", value: subtitleDisplaySummary)
            }
            NavigationLink {
                HLSAdRulesView(model: model)
            } label: {
                InfoRow(title: "广告清理规则", value: adRuleSummary)
            }
        }
    }

    /// 弹幕显示那一行的摘要：字号 / 速度 / 区域各取当前档位（一眼看出改过没有）。
    private var danmakuDisplaySummary: String {
        let display = model.danmakuDisplay
        return "\(String(format: "%.1f×", display.fontScale)) · \(display.speed.title) · \(display.area.title)"
    }

    /// 字幕显示那一行的摘要：关掉时直说「已关闭」，否则给出三档当前值。
    private var subtitleDisplaySummary: String {
        let display = model.subtitleDisplay
        guard display.isVisible else {
            return "已关闭"
        }
        return "\(String(format: "%.1f×", display.fontScale)) · \(display.position.title) · \(display.background.title)"
    }

    /// 广告清理那一行的摘要：内置 + 接口各几条、当前几条生效。
    private var adRuleSummary: String {
        let entries = model.hlsAdRuleEntries
        let builtin = model.hlsBuiltinRuleEntries
        guard !entries.isEmpty || !builtin.isEmpty else {
            return "没有规则"
        }
        let enabled = (entries + builtin).filter(\.isEnabled).count
        return "\(enabled) / \(entries.count + builtin.count) 条生效"
    }

    /// 解析器（弹幕 API）数量摘要。
    ///
    /// 刻意不用 `filter { ... }.count`（SwiftLint 的 contains_over_filter_count 偏好的写法是
    /// `contains`/等价循环），这里用 `for ... where` 数一次。
    private var parserSummary: String {
        let total = parsers.count
        guard total > 0 else {
            return "无"
        }
        var unavailableCount = 0
        for parser in parsers where !parser.availability.isAvailable {
            unavailableCount += 1
        }
        guard unavailableCount > 0 else {
            return "\(total) 个"
        }
        return "\(total) 个（\(unavailableCount) 个不可用）"
    }

    private var parsers: [ParserRule] {
        model.state.loadedSource?.config.parses ?? []
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section("数据") {
            NavigationLink {
                SettingsDownloadView(model: model)
            } label: {
                Text("下载管理")
            }
            NavigationLink {
                SettingsCacheView(model: model)
            } label: {
                Text("缓存管理")
            }
            NavigationLink {
                SettingsLogView(model: model)
            } label: {
                Text("日志管理")
            }
        }
    }

    // MARK: - 版本与群组（设置页最底部）

    /// 底部信息：当前版本号 + TG 群组入口。
    ///
    /// 版本取自 App bundle（`CFBundleShortVersionString` / `CFBundleVersion`），**不写死** ——
    /// 写死的话发版时必然忘记改。群组用 `Link` 交给系统打开（iOS 上就是 Safari），
    /// 不内嵌 WebView：这类页面用系统浏览器打开更稳，也符合「各系统用各自原生控件」的约定。
    private var aboutSection: some View {
        Section {
            InfoRow(title: "版本", value: Self.versionText)
            if let group = URL(string: Self.groupURL) {
                Link(destination: group) {
                    HStack(spacing: 8) {
                        Text("TG 群组")
                        Spacer(minLength: 8)
                        Text(Self.groupURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// 官方 TG 群组地址。
    static let groupURL = "https://t.me/YPlayerGroup"

    /// 当前版本，形如 `1.0（42）`；取不到就如实说「未知」，不编一个。
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        if short.isEmpty, build.isEmpty {
            return "未知"
        }
        if build.isEmpty || build == short {
            return short
        }
        return short.isEmpty ? build : short + "（" + build + "）"
    }
}
