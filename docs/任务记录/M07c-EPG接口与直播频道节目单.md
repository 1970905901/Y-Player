# M07c-1 EPG 接口（x-tvg）与频道节目单

- 时间：2026-10-08
- 范围：M7 第三步的前半 —— `epg` 字段里含 `{…}` 的 **x-tvg 接口**：模板展开、逐频道 × 三天拉取、
  XMLTV / JSON 两种响应、频道图标回填
- 前置：M07a（直播模型与清单解析）、M07b（XMLTV / GZ 文件解析）
- 上游依据：`FongMi/TV`（默认分支 `fongmi`）的 `api/LiveApi.java`、`api/parser/EpgParser.java`、
  `bean/Live.java`、`bean/Channel.java`、`bean/Epg.java`、`bean/EpgData.java`、`bean/Tv.java`、
  `utils/Formatters.java` —— 源码已拉到本地 `Tools/out/upstream/`（`Tools/out/fetch_upstream.py`）

## 一、这一轮落地了什么

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Live/LiveChannel.swift` | `inherit(from:)` 补上 **EPG 模板展开**：源级 `epg` 含 `{` 且频道自己不是 http 时，用 `LiveSource.epgAPI` 按 `{id}`/`{name}`/`{epg}` 展开（上游 `Channel.live(Live)` 的第二行）；`logo` 与 `epg` 共用新的私有 `expanding(template:into:)` |
| `CatVodCore/Vod/Live/EPGGuide.swift` | 新增 `channelLogos`（`<icon src>`）、`logo(for:fallback:)`、`contains(key:date:)`、`rekeyed(to:)`；`merging` 里图标与频道名一样**只补空缺** |
| `CatVodCore/Vod/Live/EPGXMLTVParser.swift` | `<channel>` 的 `<icon src>` 收进 `channelLogos`；新增 `parse(data:key:timeZone:)`：把切片键改写成**频道的 `epgID`** |
| `CatVodCore/Vod/Live/EPGJSONParser.swift` | 新件：上游 `Epg.objectFrom` 的 JSON 分支（`{"date","epg_data":[{"title","start","end"}]}`）→ 一条切片，交给 `EPGSchedule.normalized` 拼绝对时间 |
| `CatVodCore/Vod/Live/EPGTimeParser.swift` | `dateString(dayOffset:timeZone:from:)`（上游 `LocalDate.now(zone).plusDays(offset)`） |
| `CatVodSource/Live/LiveEPGRepository.swift` | 新增 `load(channel:source:existing:dayOffsets:)`：逐频道 × 昨天/今天/明天；`existing` 已有那天就**跳过请求**；单天失败不影响其它天；非 http 跳过；URL 里的非 ASCII 按 OkHttp 的习惯补编码 |
| `CatVodCore/Vod/Models/LiveSource.swift` | 复核上游字段表时补上 `boot`（开机自启直播；界面暂时没有入口，先按上游存着） |
| 单测 | `EPGJSONParserTests`（5）、`EPGXMLTVParserTests` +2、`EPGTimeParserTests` +1、`LivePlaylistParserTests` +1、`LiveEPGInterfaceTests`（6） |

## 二、逐条对齐（上游 → 本仓库）

| 上游 | 本仓库 |
| --- | --- |
| `Live.getEpgApi()`：`epg` 逗号串里含 `{` 的那一项 | `LiveSource.epgAPI`（M07a） |
| `Channel.live(Live)`：`live.getEpg().contains("{") && !getEpg().startsWith("http")` → 展开 `{id}` / `{name}` / `{epg}` | `LiveChannel.inherit(from:)` 的第二段（本次补） |
| `LiveApi.getEpg(item, zoneId)`：`for (offset : {-1, 0, 1}) fetchEpgDay(...)`，最后取「今天」那一片 | `load(channel:source:existing:dayOffsets: [-1, 0, 1])`；界面取「正在播 / 下一档」用 `EPGGuide.currentProgram/nextProgram`（M07b 已有） |
| `fetchEpgDay`：`url = item.getEpg().replace("{date}", date)`；`url.startsWith("http")` 才请求；`getDataList()` 里已有这天就跳过 | 同（`EPGTimeParser.dateString` + `EPGGuide.contains(key:date:)` + `percentEncoded` 兜底） |
| `Epg.objectFrom(str, key, zone)`：是 JSON 对象 → `Epg`；否则走 `EpgParser.getEpg`（XMLTV） | `EPGJSONParser.parse(data:key:timeZone:)`，拿不到再 `EPGXMLTVParser.parse(data:key:timeZone:)` |
| `EpgParser.getEpg(xml, key, zone)`：解析单个频道的 XMLTV，键用**传入的 key** | `EPGXMLTVParser.parse(data:key:timeZone:)` = 整文件解析 + `EPGGuide.rekeyed(to:)` |
| `EpgParser.prepareLiveChannels`：`tvgId` → `tvgName` → `name` 三级映射 | `LiveChannel.epgID`（M07a） |
| `EpgParser.bindResultsToLive`：`<icon src>` 回填给没写 `logo` 的频道 | `EPGGuide.channelLogos` + `logo(for:fallback:)`（模型不就地改，取值时回填） |
| `EpgParser.refreshReason`：文件「不是今天 / 超过 6 小时」才重下 | **M07d7 已落盘并对齐三条规则**（`EPGFileCachePolicy`）；`existing` 参数仍是接口形态的内存缓存入口 |
| `EpgData.getRange()`（`clock=…`） | `EPGProgram.clockQuery`（M07a）——**不是 EPG 请求参数**，见下方差异 2 |

## 三、差异与取舍

1. **接口返回的是 XMLTV，不是 JSON**：M07b 的注释写反了一句（「拼 `clock=` 再按 JSON 解析」），本轮改正 ——
   上游接口分支走 `EpgParser.getEpg`（SimpleXML 解 XMLTV）；JSON 形态是 `Epg.objectFrom` 的另一个分支
   （缓存/其它调用方）。两种在 `LiveEPGRepository.loadDay` 里都支持，判断顺序与上游一致。
2. **`clock=` 不在 EPG 请求里**：上游 `getRange()` 是给**直播地址**用的 ——
   `LiveApi.getUrl(item, data)` 用 `getCatchup().format(url, data)` 拼时移地址，并在 rtsp 场景加 `rtsp_range` 头。
   所以 `clockQuery` 的接线属 M07c-2（直播页的时移播放）。
3. **请求带源级 header**：上游 `OkHttp.string(url)` 用默认头；本项目沿用 M07b 的口径
   （`LiveSource.headers()` + `timeout`），对需要 UA / Referer 的接口更稳。
4. **当时的「不落盘」是有意为之**：上游把 EPG 落到自己目录并按「跨天 / 6 小时」判定刷新；
   本项目当时把「已经拿到的那天」交给调用方（`existing`）在内存里持有，不在沙盒里造第二套缓存目录。
   **M07d7 起收回一半**：文件形态（整源 XML / GZ）落了盘、三条规则对齐（见 M07d7）；
   接口形态（逐频道 × 天）仍只在内存 —— 落盘会变成几百个小文件，淘汰规则得先想清楚。
5. **接口没给 `date` 时按源时区今天**：上游会把空日期拼进 `date + HH:mm` → 时间退化成 1970；
   `EPGJSONParser` 改成今天，并在代码里记了这一条。
6. **非 ASCII 编码**：上游只用 `replace`，中文频道名靠 OkHttp 规整 URL；
   本项目在 `URL(string:)` 造不出来时补百分号编码（`percentEncoded`），其余情况原样交给 `URL`。
7. **`core` 未接**：上游 `Live.core` 是 tvbus / Core 引擎注入（`auth`/`broker`/`resp`/`sign`/`pkg`/`so`/… 十来个字段），
   属播放内核阶段，本轮只在 `docs/协议兼容矩阵.md` 记一笔。

## 四、验证

- 本地：`Tools/out/paren_check.py`（按状态机处理 `"…"`、`#"…"#`、`\"`、`"""`）对 11 个改动文件逐行核查通过；
  旧的 `syntax_scan.py` 对两处 `#"…"#` + `\"` 报了「圆括号差 1」，已确认是它的启发式误报。
- CI：SwiftPM tests（Core / Source / UI 全跑）+ Lint + 双端未签名构建，见本次提交的 CI 记录。

## 五、下一步（M07c-2：直播页）

- 入口：~~发现页工具栏的**纸飞机按钮**~~ → **已改为底部 Tab「直播」**（M07c-6，按用户指定；
  反转理由见 `docs/任务记录/M07c6-直播入口改底部Tab.md`。原方案是参考录屏的纸飞机入口 ——
  上游手机版也走 `LiveActivity.start(this)` 的 push 形态，不是第 4 个 Tab）。
- 界面：分组 → 频道列表（当前节目显示「正在播」，点历史节目走时移），播放复用现有 `PlaybackView`
  （系统 `AVPlayer` + 本地代理注入 header）。
- 顺带接线：图标回填（`logo(for:fallback:)`）、时移（`LiveCatchup` + `EPGProgram.clockQuery`）、`keep`（上次观看位置）。

## 六、M07c-2 进度与交接

> **M07c-5 修正（同一批直播工作）**：「上次观看」的分组不再由界面传进来，改成**按频道名回查**
> （`LiveKeep.locate(channelNamed:in:line:)`），并补上上游 `LiveConfig.setKeep` 的闸门
> 「加密分组里的频道不记」。原因：收藏分组里的频道是清单的副本，界面并不知道它真正的分组。
> 详见 `docs/任务记录/M07c5-直播收藏频道.md`。

已落地（提交见 `git log`）：

| 件 | 说明 |
| --- | --- |
| `CatVodUI/LiveLayout.swift` | 纯逻辑：分组行（名字 / 频道数 / 加密标记）、频道行（EPG 覆盖显示名与图标、`epgID` 三级回落、「正在播 / 下一档」文案、时移入口判定含 `/PLTV/` 自动套用） |
| `CatVodUI/LiveView.swift` | 直播页：顶部分组条（当前分组加粗、加密组带锁）+ 频道列表（图标 / 名字 / 正在播 / 回看标记 / 频道号）；空态 / 加载中 / 失败三种分支都给真话；播放复用 `PlaybackView` + `proxiedMediaResource(_:)` |
| `CatVodUI/AppModel+Live.swift` | `liveSources`（配置 `lives`）、`selectedLiveSource` / `selectedLiveGroupObject`（选择落 `UserDefaults`）、`loadLivePlaylist(force:)`（换源清节目单缓存）、`loadLiveGuide(for:)`（失败只留 `liveEPGNotice`，不弹错） |
| `CatVodUI/RootView` | 底部 Tab 新增「直播」（M07c-6 入口从发现页工具栏改到这里，见 `M07c6-直播入口改底部Tab.md`） |
| 单测 | `LiveLayoutTests`（6 例：分组行 / EPG 覆盖名字与图标 / `epgID` 回落 / 无节目单回落 / 时移入口 / 顺序与可播放） |

未做（下一步）：

1. **时移回看**：频道行里点历史节目 → 用 `LiveCatchup.playbackURL(_:start:end:)` 拼那一段的地址（`EPGProgram.clockQuery` 是给 rtsp 的 `rtsp_range` 用的）→ 直接进 `PlaybackView`；需要一个「当天节目单」的展开入口（上游是 `EpgDialog`）。
2. ~~**`keep` 上次观看位置**~~ → **已在 M07c-3 落地**（`LiveKeep` 编解码 + `LiveKeepBook` 存档 +
   直播页的「继续观看」入口）。上游编解码已核实（`Live.keep(Channel)` + `AppDatabase.SYMBOL`）：
   **`分组名@@@频道名@@@线路下标`**，分隔符是字面量 `@@@`。注意上游另有独立的 `Keep` 表做「收藏频道」，
   与这个字符串字段（上次观看位置）不是一回事，别混。
3. ~~**线路切换**~~ → **已在 M07c-3 落地**（播放页右上角的线路菜单，换线路写回 `keep`；
   时移地址也改成按当前线路拼）。
4. ~~**EPG 拉取时机**~~ → **已在 M07c-4 落地**：文件形态进页面拉一次（对齐上游 `LiveActivity`
   → `parseXml`）；接口形态按「可见频道排队预取」（串行 / 去重 / 失败不重试 / 本次进入封顶 12 个，
   换分组重置），跨天靠 `EPGGuide.coversToday()` 判重拉。

