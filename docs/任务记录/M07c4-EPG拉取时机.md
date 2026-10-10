# M07c-4 EPG 拉取时机（文件形态接线 + 可见即预取）

- 状态：本机自检已过；CI 见文末「验证记录」（本轮 CI 攒着一起看）
- 时间：2026-10-08
- 范围：M07c 的第四批 —— ① **文件形态 EPG 的接线**（此前根本没有调用点）；② 接口形态的
  「可见频道排队预取」；③ `liveEPGNotice` 真正显示出来（此前只写不读）
- 前置：M07b（XMLTV/GZ 解析）、M07c（接口形态与节目单页）、M07c-2/-3（直播页与 keep）
- 上游依据：`Tools/out/upstream/` 里的 `api/LiveApi.java`（`parseXml` / `getEpg` / `fetchEpgDay`）、
  `api/parser/EpgParser.java`（`start` / `refreshReason`）、
  `ui/activity/LiveActivity.java`（`onLiveParsed` → `mViewModel.parseXml(live)`、`mViewModel.getEpg(mChannel)`）

## 一、先修的那个洞

`LiveEPGRepository.load(_ source:)`（**文件形态**：`epg` 里的 `.xml` / `.gz`）此前**只有单测在用**，
App 里一个调用点都没有 —— 于是：

- 配 `epg: "http://…/epg.xml"` 的源，每个频道都显示「暂无节目」（`channel.epg` 为空，
  逐频道那条路会直接判「没有可用的节目单地址」）；
- 而「首屏没有节目名」这件事，根因不是「没预取」，是**这条路压根没接**。

上游的对应动作很明确：`LiveActivity.onLiveParsed(live)` → `mViewModel.parseXml(live)`（整源文件），
频道切换时才是 `mViewModel.getEpg(mChannel)`（逐频道接口）。这一轮把这层对齐。

## 二、这一轮落地了什么

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Live/EPGGuide+Freshness.swift` | 新增 `coversToday(key:now:)`（某频道今天有没有）与 `coversToday(now:)`（整份里有没有今天），都按**这份节目单自己的时区**算「今天」 |
| `AppModel.liveFileGuide` | 源级文件节目单（一份覆盖多频道）。`liveGuide(for:)` 改成「接口形态按频道存的优先，否则用文件那份」，界面与行模型不用区分两种形态 |
| `AppModel+Live.loadLiveFileGuide(force:)` | 进页面（清单到手后）拉一次；`force` 或「缺今天」才重下 |
| `AppModel+Live.requestLiveGuide(for:)` | 频道行露面时排队；由 `LiveEPGPrefetch`（纯函数）判定「值不值得拉」 |
| `LiveEPGPrefetch.swift` / `LiveEPGPrefetchState.swift` | 判定规则 + 判定输入：没配 x-tvg 地址 / 今天已有 / 已在队列 / 失败过 / 到封顶 → 不排队 |
| `AppModel+Live` 队列 | 串行抽干（一次一个请求）、出队即摘「在飞」、失败进 `liveEPGFailed`（本次进入不重试）、封顶 `LiveEPGPrefetch.defaultBudget = 12` |
| `LiveView` | 页面 `.task` 里先 `loadLivePlaylist()` 再 `loadLiveFileGuide()`；每一行的 `.task` 里 `requestLiveGuide(for:)`；列表上方显示 `liveEPGNotice` |
| `LiveScheduleView` | 空节目单时把原因写出来（`liveEPGNotice`），不再给一个空白弹层 |
| 单测 | `CatVodCoreTests/EPGGuideFreshnessTests`（3 例）+ `CatVodUITests/LiveEPGPrefetchTests`（5 例） |

## 三、逐条对齐与差异

| 上游 | 本仓库 | 差异 |
| --- | --- | --- |
| `LiveActivity.onLiveParsed` → `LiveApi.parseXml(live)`：清单到手就拉整源文件 | `LiveView.task` → `loadLivePlaylist()` → `loadLiveFileGuide()` | 上游落盘并按「不是今天 / 超过 6 小时」判重下（`EpgParser.refreshReason`）；**M07d7 起本项目也落盘、三条规则逐条对齐**（当时「不落盘、只看缺今天」是这一轮的权宜；逐频道仍只在内存） |
| 频道切换 → `mViewModel.getEpg(mChannel)` | 打开频道 / 打开节目单 → `loadLiveGuide(for:)` | 多了「今天已有就短路」：文件形态覆盖今天时不必再按频道请求，也就不会走「没有接口地址」那条错 |
| 上游不预取（只拉选中频道） | 频道行露面即排队预取 | **本项目加的**，所以自带刹车：串行、去重、失败不重试、本次进入封顶 12 个、换分组重置 |
| — | 封顶到顶时把原因写进 `liveEPGNotice` | 「不静默」：用户看得到「已预取 12 个，其余点开再拉」 |

取舍理由（写在代码注释里，这里只留结论）：

1. **封顶 12**：一个频道走接口形态最多 3 个请求（昨天/今天/明天），12 个 ≈ 36 个请求、约一屏多一点；
   不封顶的话，几百个频道的列表滚一遍就是几百次请求。
2. **失败不重试（本次进入）**：列表行会在滚动中反复出现，不记住失败就成了重试风暴；点开频道仍会重试（明确的用户动作）。
3. **粒度按键、时区跟着节目单走**：`coversToday(key:)` 用 `EPGGuide.timeZone`，所以「跨天」判断与源时区一致，
   不会因为本机时区而提前/延后重拉。
4. **预取失败不写 `liveEPGNotice`**（`quiet`）：滚一遍长列表时逐个频道的失败提示没有意义，只影响那一行。

## 四、验收

- 本机自检（无 Swift 工具链）：`Tools/out/check_swift.py`、`Tools/out/check_wrap.py`、
  `Tools/out/check_fixtures.py`。
- CI：Lint + SwiftPM tests（本轮起 `CatVodUI`/`CatVodUITests` 真的会跑，见上一提交）+ 双端未签名构建。
- 人工（需真机 / Mac）：
  1. 用**文件形态**的源（`epg` 指向 `.xml` 或 `.xml.gz`）进直播页 → 首屏每行都有「正在播」；
  2. 用**接口形态**的源进直播页 → 首屏可见的十几行陆续显示节目名，列表上方不出现错误提示；
  3. 长列表往下滚 → 请求是**串行**的（一次一个），滚过 12 个频道后出现「已预取 12 个，其余点开时再拉」；
  4. 换分组 → 计数重置，新分组的可见频道重新预取；回到已看过的分组 → **不重复请求**；
  5. 点开某个频道 → 即使超出封顶也会即时拉一次；
  6. 节目单拿不到的源 → 列表上方有一句人话说明原因（不是全屏「暂无节目」且不知道为什么）。

## 五、回滚

删掉 `EPGGuide+Freshness.swift` / `LiveEPGPrefetch.swift` / `LiveEPGPrefetchState.swift` 与
`AppModel.liveFileGuide` / 队列那几个字段，恢复 `AppModel+Live.liveGuide(for:)` / `loadLiveGuide(for:)`
与 `LiveView` 的 `.task` 即可；`LiveEPGRepository` 本身不用动（文件形态那条路留着仍可单测）。

## 六、验证记录

- **Lint / SwiftPM tests：✅**（`be5b86c`）。本轮 CI 连红三轮才绿（SwiftFormat 7 处、CatVodUI 单测首次编译、
  两个老用例的过期断言），逐轮复盘见 `docs/任务记录/M07d2-直播源切换.md` 第六节。
- 本任务的用例都在绿的那一轮里真跑过：`EPGGuideFreshnessTests`（3 例）、`LiveEPGPrefetchTests`（5 例）。
  预取判定（`LiveEPGPrefetch`）的封顶/去重/失败不重试三条规则都有断言覆盖。
- **`Build apps (unsigned)` / `Unsigned IPA`：✅**（`d5d2cab`）—— iOS 侧由 `Unsigned IPA` 作业真实构建打包，
  iOS 15 下限类 API 这一关过了；逐条复盘见 `docs/任务记录/M07d2-直播源切换.md` 第六节。
