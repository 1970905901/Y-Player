# M07d-1 直播 EPG 地址的本地覆盖与历史

- 状态：本机自检已过；CI 见文末「验证记录」（本轮 CI 攒着一起看）
- 时间：2026-10-08
- 范围：直播设置的第一步 —— **EPG 地址的本地覆盖**：填一个自定义地址（x-tvg 模板或整源 XML）
  顶掉源自己配的 EPG，另留最近 20 条历史；入口在直播页工具栏的齿轮里
- 前置：M07c-4（EPG 拉取时机：文件形态接线 + 可见即预取）
- 上游依据：`Tools/out/upstream-LiveEpgSetting.java`（`live_epg_url` / `live_epg_history` /
  `MAX_HISTORY = 20` / `getEffectiveUrl` / `isGlobalXmlUrl` / `getXmlUrls` / `apply(live, channel)` /
  `removeHistory` / `clearHistory`）

## 一、这一轮落地了什么

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Live/LiveEPGOverride.swift` | 覆盖的**生效规则**（纯函数）：`isEmpty` / `isGlobalXML` / `applying(to:)` / `fileURLs(for:)` |
| `CatVodSource/Live/LiveEPGRepository.swift` | 新增 `load(_:fileURLs:)`：文件形态的地址由调用方给全（覆盖地址可能不带 `xml` / `gz` 字样，过不了 `epgXML` 的过滤） |
| `CatVodUI/LiveEPGSetting.swift` | 覆盖地址 + 历史（上限 20、去重置顶、坏存档当默认）+ JSON 落 `UserDefaults` |
| `CatVodUI/LiveEPGSettingView.swift` | 直播设置页：地址输入 + 「使用这个地址」/「清除覆盖」+ 历史（点一条即用、可单条删、可清空）+ 当前状态三种形态的说明 |
| `CatVodUI/LiveView.swift` | 工具栏齿轮 → 「直播设置」弹层（`AdaptiveNavigationContainer` 承载，右上角「完成」关掉） |
| `AppModel` / `AppModel+Live` | `liveEPGSetting`（写一次落盘 + 重算）、`rawLiveSource`（未套覆盖的解析结果）、`applyLiveEPGOverride()`、`updateLiveEPGSetting(_:)` / `removeLiveEPGHistory(_:)` / `clearLiveEPGHistory()` |
| 单测 | `CatVodCoreTests/LiveEPGOverrideTests`（4 例）、`CatVodSourceTests/LiveEPGRepositoryTests` +1 例（显式地址列表）、`CatVodUITests/LiveEPGSettingTests`（4 例） |

## 二、逐条对齐（上游 → 本仓库）

| 上游 | 本仓库 |
| --- | --- |
| `LiveEpgSetting.getUrl()` / `putUrl(url)`（`normalize` = trim） | `LiveEPGSetting.url` / `using(_:)`（顺带记历史） |
| `getEffectiveUrl(live)`：自定义优先，否则 `live.getEpgApi()` | `LiveEPGOverride.applying(to:)`：`epg` 改成「覆盖地址 + 源自己的文件」，`epgAPI` 取第一个含 `{` 的项 → 覆盖顶掉模板 |
| `isGlobalXmlUrl(url)`：非空且不含 `{` | `LiveEPGOverride.isGlobalXML` |
| `apply(live, channel)`：`channel.setEpg("")`，整源 XML 时直接返回，否则按 `{id}`/`{name}`/`{epg}` 展开 | `applying(to:)` 里对每个频道「先清空再 `inherit(from:)`」——`inherit` 只在频道自己为空时才展开模板 |
| `getXmlUrls(live)`：自定义的整源 XML（如果有）+ `live.getEpgXml()`（`LinkedHashSet` 去重） | `LiveEPGOverride.fileURLs(for:)`（去重保序），交给 `LiveEPGRepository.load(_:fileURLs:)` |
| `live_epg_history`：最近在最前、去重、`MAX_HISTORY = 20` | `LiveEPGSetting.history` + `normalizedHistory(_:)` |
| `removeHistory(url)`：从历史删；正好是当前用的那条则把 `KEY_URL` 清空 | `removing(_:)` 同 |
| `clearHistory()` | `clearingHistory()`（不动当前覆盖） |

## 三、差异与取舍

1. **地址是全局一份**（上游语义）：对所有直播源生效。好处是与上游一致、不会出现「这个源有覆盖那个没有」
   的困惑；代价是填错会同时影响所有源 —— 所以历史（20 条）与「清除覆盖」都必须一眼可见，
   设置页里也写明「对所有直播源生效」（不藏）。
2. **不改配置副本，只套在解析结果上**：本项目没有可写的配置副本，所以覆盖是**运行时**套用：
   `AppModel` 留一份 `rawLiveSource`（原始解析结果），`liveState` 里那份是套用后的。这样
   「清掉覆盖」能把频道地址原样还回去，也不必为了改地址重拉一遍清单（上游是就地改对象，值类型做不到）。
3. **文件地址列表单独传**：覆盖地址可能写成 `…/epg.php`（不带 `xml` / `gz` 字样），
   按 ``LiveSource/epgXML`` 的过滤会漏掉，所以 `load(_:fileURLs:)` 由调用方给全 ——
   这也是上游 `getXmlUrls` 存在的原因（它不看扩展名）。
4. **改完立刻生效**：换地址 → 频道地址重算（同步）→ 节目单缓存整体作废 → 文件形态立刻重拉；
   逐频道那些由列表的「可见即预取」自然重来（缓存清空后 `shouldQueue` 会重新排队）。
   删历史里**无关**的一条不发请求（只有地址真的换了才重拉）。
5. **入口只有一处**：直播页工具栏的齿轮。不往设置树里再放一份 —— 两个入口指向同一件事，
   只会让人以为它们不一样。
6. **明确未做**：上游还按「不是今天 / 超过 6 小时」判文件缓存是否重下（`EpgParser.refreshReason`），
   本项目不落盘，只用「缺今天」那一半（M07c-4 起就这样）；`LiveSetting` 里的其它字段
   （分组密码 `pass`、开机自启 `boot` 的本地开关）留到下一步。

## 四、验收

- 本机自检：`Tools/out/check_swift.py`（+ `scan_report.py` 过滤工作区 CRLF 噪音）、
  `Tools/out/check_wrap.py`。
- CI：Lint + SwiftPM tests（`CatVodCore` / `CatVodSource` / `CatVodUI`）+ 双端未签名构建。
- 人工（需真机 / Mac）：
  1. 直播页工具栏齿轮 → 直播设置：填一个整源 XML 地址 → 「使用这个地址」→ 关掉弹层；
  2. 列表里那些频道开始显示节目名（逐频道请求全部改为这一次文件请求）；
  3. 再填一个含 `{id}`/`{date}` 的模板地址 → 频道按模板逐个请求（换源后依然生效，因为覆盖是全局的）；
  4. 历史里能看到刚用过的地址（最近在最前、不重复），点一条即切过去；删掉**正在用**的那条 → 覆盖被清掉、
     回到源自己的 EPG；
  5. 「清除覆盖」→ 频道地址回到源自己的配置，「继续观看」/收藏等其它状态不受影响；
  6. 杀掉进程重开 → 覆盖与历史仍在（落 `UserDefaults`）。

## 五、回滚

删掉 `LiveEPGOverride.swift` / `LiveEPGSetting.swift` / `LiveEPGSettingView.swift` 与
`AppModel.liveEPGSetting` / `rawLiveSource` / `AppModel+Live` 里那几个入口，`LiveView` 的齿轮与弹层，
并把 `loadLivePlaylist` 改回「`liveState = .loaded(loaded)`」即可；
`LiveEPGRepository.load(_:fileURLs:)` 可以留着（它只是多一个显式地址列表的入口）。

## 六、验证记录

（推送后回填。）
