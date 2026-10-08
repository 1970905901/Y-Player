# M07c-6 直播入口改到底部 Tab

- 状态：本机自检已过；CI 见文末「验证记录」（本轮 CI 攒着一起看）
- 时间：2026-10-08
- 范围：直播的入口从「发现页工具栏的纸飞机按钮」改成**底部 Tab 的「直播」**；顺带处理
  「Tab 是常驻视图」带来的接口切换重载（与 M02P9 同一类问题）
- 前置：M07c-2（直播页）、M07c-3（keep / 线路）、M07c-4（EPG 时机）、M07c-5（收藏）
- 依据：**用户指定**（「先把直播改到底部 tab」）。这是一次**决定反转**，不是发现原实现有错 ——
  原始决定见 `docs/任务记录/M07c-EPG接口与直播频道节目单.md` 第五节

## 一、改了什么

| 件 | 说明 |
| --- | --- |
| `CatVodUI/RootView.swift` | `TabView` 增加第 2 个 Tab：「直播」（`Label("直播", systemImage: "dot.radiowaves.left.and.right")`），顺序为**发现 / 直播 / 追剧 / 设置**；类注释从「三个原生 Tab」改成四个并记下这次改动 |
| `CatVodUI/HomeView.swift` | 工具栏去掉纸飞机入口，右上角恢复成「刷新 + 搜索」两个按钮（注释里写明直播入口现在在哪儿、为什么不在这里） |
| `CatVodUI/LiveView.swift` | 头注释改成「入口是底部 Tab」；新增 `.onChange(of: model.siteCatalogRevision)` → 强制重载清单与文件形态节目单 |
| 文档 | 本文件；`M07c-EPG接口与直播频道节目单.md` 与 `docs/协议兼容矩阵.md` 里关于入口的描述同步改写（原文用删除线保留，不装作一开始就这么定） |

## 二、为什么反转，以及反转的代价

- **原决定的依据**是参考录屏（三个 Tab：发现 / 追剧 / 设置，直播在发现页工具栏的纸飞机按钮里）
  加上上游手机版的形态（`LiveActivity.start(this)` 是 push 出去的独立 Activity，不是底部 Tab）。
  本轮按用户指定改成底部 Tab —— 信息架构上直播从「发现的附属功能」升成一级入口，取舍如下：
  - 得：入口一眼可见、少一跳；直播是高频入口，藏在工具栏图标里确实偏深。
  - 失：底部多一个 Tab；且**Tab 是常驻视图**，`.task` 在回到该 Tab 时不保证重跑（M02P9 踩过），
    所以「换接口后直播页要跟着换」这件事必须自己接线，否则会一直显示上一个接口的频道。
- **代价已经补上**：`LiveView` 监听 `model.siteCatalogRevision`（换配置 / 宿主刷新 / 宿主停止都会自增），
  收到就 `loadLivePlaylist(force: true)` + `loadLiveFileGuide(force: true)`。用非结构化 `Task`：
  离开这个 Tab 时这次重载不该被取消（与首页同一写法）。
- **没有保留第二个入口**：纸飞机按钮删掉了。两个入口指向同一页会让人以为其中一个有别的用途。

## 三、取舍

1. **没有 `lives` 时 Tab 不能置灰**：系统 `TabView` 没这个能力。所以这个 Tab **始终在**，
   没有直播源时由页内空态说明（「当前接口里没有直播源。可在『设置 → 源地址』里换一个带 `lives` 的配置。」）
   —— 比「Tab 忽然不见了」好解释。
2. **Tab 顺序**：发现 / 直播 / 追剧 / 设置。直播紧挨发现（都是「看内容」），追剧是「我看过的」，
   设置最后。上游手机版底部是首页 / 直播 / 设置这类分区，顺序不必逐一对齐，这里按内容亲疏排。
3. **图标**：`dot.radiowaves.left.and.right`（SF Symbols 1.0 起就有，不踩 iOS 15 下限）。
   没用 `paperplane` —— 那是原工具栏按钮的隐喻，做 Tab 图标语义不清楚。
4. **未做**：Tab 上的角标 / 未读（没有这种语义）、Tab 记忆（`selectedTab` 未落盘；
   系统自己会保持本次运行的选中 Tab）。

## 四、验收

- 本机自检：`Tools/out/check_swift.py`（+ `scan_report.py` 过滤工作区 CRLF 噪音）、
  `Tools/out/check_wrap.py`。
- CI：Lint + SwiftPM tests + 双端未签名构建。
- 人工（需真机 / Mac）：
  1. 底部是**四个** Tab：发现 / 直播 / 追剧 / 设置，直播图标是同心电波；
  2. 进「直播」→ 选源 / 分组 / 频道 / 播放 / 节目单 / 长按收藏，与改之前一致；
  3. 发现页工具栏只剩「刷新 + 搜索」，没有纸飞机，也没有别的入口能再进直播页；
  4. 在「设置 → 源地址」换一个接口 → 回到「直播」Tab：显示的是**新接口**的直播源与频道
     （不是旧接口的残留；这是本次补的那段 `.onChange`）；
  5. 没有 `lives` 的接口：直播 Tab 仍在，页内给出「当前接口里没有直播源…」的空态说明。

## 五、回滚

`RootView` 删掉「直播」那一段 `AdaptiveNavigationContainer { LiveView(model: model) }`，
`HomeView.trailingButtons` 里把纸飞机那个 `NavigationLink { LiveView(model: model) }` 加回去，
`LiveView` 头注释与 `M07c-EPG接口与直播频道节目单.md` / 协议兼容矩阵里的入口描述改回原样即可。
`.onChange(of: model.siteCatalogRevision)` 建议保留 —— 直播页不再常驻时它也没坏处。

## 六、验证记录

- **Lint / SwiftPM tests：✅**（`be5b86c`）。本轮 CI 连红三轮才绿，逐轮复盘见
  `docs/任务记录/M07d2-直播源切换.md` 第六节。
- **本任务没有新增单测**：Tab 入口与 `.onChange` 重载都是界面行为，没有可纯函数化的部分；
  `RootView` 的四 Tab 结构靠「人工看一眼」+ 编译把关。
- **`Build apps (unsigned)` / `Unsigned IPA`：✅**（`d5d2cab`）—— iOS 侧由 `Unsigned IPA` 作业真实构建打包，
  四 Tab 与新写的 SwiftUI 代码都过了 iOS 15 下限这一关；逐条复盘见 `docs/任务记录/M07d2-直播源切换.md` 第六节。
