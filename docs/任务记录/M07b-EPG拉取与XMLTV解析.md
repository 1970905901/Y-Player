# M07b EPG 拉取与 XMLTV 解析

- 状态：**Lint 与 SwiftPM tests 已绿**（见第七节；双端未签名构建在同一 run 里随后跑）
- 时间：2026-10-08
- 范围：M7 第二步 —— 把 `epg` 字段里的 **XML/GZ 节目单文件**拉下来、解析成 `EPGGuide`
  （纯逻辑 + 一个仓库）；直播页 UI 与 x-tvg 接口（含 `{…}` 时间窗）分别是 M07c / 后续
- 前置：M07a（`LiveSource.epg` 拆分、`EPGSchedule` / `EPGProgram` / `EPGTimeParser` 已在 M07a 落地）

## 一、产出

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Live/EPGGuide.swift` | EPG 全集：`schedules`（按「频道 + 日期」切片）+ `channelNames`；查询 `schedule(key:date:)` / `currentProgram(key:at:)` / `nextProgram(key:at:)` / `displayName(for:fallback:)`；`merging(_:)` 多文件合并 |
| `CatVodCore/Vod/Live/EPGXMLTVParser.swift` | XMLTV → `EPGGuide`（`XMLParser` 状态机）：`<channel>` 取显示名、`<programme>` 取时间与标题；时间串规整（`T` / `Z` / `+08:00`）；按源时区切片并**当场算好绝对时间** |
| `CatVodSource/Live/GZipDecoder.swift` | gzip 解压（RFC 1952 头尾 + 系统 `Compression` 的裸 DEFLATE）；`looksLikeGzip(_:)` 按魔数判断 |
| `CatVodSource/Live/LiveEPGRepository.swift` | 取节目单：多地址逐个拉取并合并、源级 header/超时、`.gz` 自动解压、错误语义（**全失败才算失败**） |
| 单测 | `EPGXMLTVParserTests`（6 例）、`LiveEPGRepositoryTests`（6 例，含 gzip 夹具） |

## 二、逐条对齐（上游 → 本仓库）

| 上游 | 本仓库 |
| --- | --- |
| `EpgParser.parseXml` | `EPGXMLTVParser.parse(data:timeZone:)` |
| `EpgParser` 的静态缓存 `Map<String, Epg>` | 值类型 `EPGGuide`（一个源的节目单就是一个值，界面按 `epgID` 取） |
| `getInRange()` / `isFuture()` | `EPGGuide.currentProgram(key:at:)` / `nextProgram(key:at:)`（**跨切片**找：XMLTV 常一次给 1~3 天） |
| `EpgData(title, start, end)` | `EPGProgram`（`HH:mm` 展示串 + 绝对时间） |
| Java `GZIPInputStream` | `GZipDecoder`（`Compression` + 手工跳过 gzip 头尾） |

## 三、设计取舍

1. **当场算好绝对时间**：切片按「源时区日期」切，`HH:mm` 展示串与 `startTime`/`endTime` 出自同一套时区，
   所以界面与仓库都不用再调 `normalized`；真调也幂等（`date + HH:mm` 与 `parseFull` 同源）。
2. **多文件合并在节目级**：两个文件都覆盖同一频道同一天时不会互相顶掉，而是按 `start-end-title`
   去重后拼在一起并重排（`merging(_:)`）。
3. **gzip 按魔数判断**：地址里没有 `.gz` 但响应体是 gzip 的情况真实存在（`?gz=1` 这类），扩展名不可信。
4. **缺 `stop` 取开始时间**：上游也不推断「下一档开始时间」；给零长度节目比给 1970 年诚实。
5. **丢掉没有标题 / 时间解析失败的条目**：这种条目在界面上只会显示成空行或 1970 年。
6. **一个地址坏不拖垮整批**：记下第一个错误，全部拿不到才抛（错误里带地址前缀，便于对配置）。

## 四、超出 / 未做（诚实记录）

1. **时间写法三条加固**（上游没有）：`20261007T190000+0800`、`…Z`、`…+08:00`。
   上游 `parseFull` 只认 `yyyyMMddHHmmss ±HHMM`，这三种会被解析成 epoch；真实 XMLTV 里都见过，
   所以先规整（`EPGXMLTVParser.normalizedTime`）再交给上游同款解析逻辑。
2. ~~**x-tvg 接口未做**~~ → **已由 M07c 落地**（见 `docs/任务记录/M07c-EPG接口与直播频道节目单.md`）：
   当时 `epg` 里含 `{…}` 的地址一律**明确报错**、不静默返回空节目单；现在走
   `LiveEPGRepository.load(channel:source:existing:)` 逐频道拉。
   ⚠️ 顺带更正当时的两处判断：接口返回的是 **XMLTV**（上游 `EpgParser.getEpg` 用 SimpleXML 解析），不是 JSON；
   `EPGProgram.clockQuery` 也不是 EPG 请求参数，而是**时移直播地址**用的（见 M07c 差异 1 / 2）。
3. **繁简转换不做**（上游 `Trans.s2t`）：与 M07a 的口径一致。
4. **`<desc>` / `<rating>` 不解析**：`EPGProgram` 没有这些字段，界面也用不到。
   `<channel>` 的 `<icon src>` **会收**（频道图标回填，M07c 补）。
5. **没有缓存**：每次进直播页都重新拉。TTL 等 M07c 有界面再定，避免现在猜一个数
   （详情缓存 M02P5 的 300s 是另一码事）。
6. **没走本地代理**：节目单是普通 GET，直接走 `HTTPTransport`；播放侧才需要 `/proxy`。

## 五、验收

- 单测：`EPGXMLTVParserTests`（基本切片 / 跨天 / 正在播与下一档 / 时间写法 / 容错 / 合并）、
  `LiveEPGRepositoryTests`（正常 / `.gz` 两种头 / 多地址部分失败 / 无可用地址 / 坏响应 / 魔数识别）。
- 待跑：`swift test --package-path Packages/CatVodCore`、`--package-path Packages/CatVodSource`、
  SwiftLint / SwiftFormat、双端未签名构建。
- 人工：现在只能靠单测（直播页 UI 属 M07c）。

## 六、本机限制与自检

- 本机（Windows）没有 Swift 工具链，编译与 lint 只能在 Mac/CI 上跑；
  本轮用 `Tools/out/check_batch.py` 做语法/格式卫生预检，结果落 `Tools/out/check-batch.txt`。
- gzip 夹具由 `Tools/out/make_epg_fixture.py` 生成（同一份 XML 的两种 gzip 头形态：`FLG=0` 与带 `FNAME`）。

## 七、验证记录（本轮 CI）

| 提交 | 结果 | 说明 |
| --- | --- | --- |
| `81e35b9` | ❌ Lint | SwiftFormat 三条：`redundantLetError`（`catch let error`）、`numberFormatting` ×2（十六进制字母要大写）；外加一条**解析失败** —— 我用脚本把 gzip 夹具改成数组拼接时丢了 `private let gzipPlain = [` 声明行，文件语法是坏的 |
| `a877afb` | — | 只动文档与 `Scripts/pick_simulator.sh` 注释（校准陷阱 21/22） |
| `ee91ac7` | ❌ Lint（其余作业被后一次推送取消） | 修掉上一轮三条（夹具改回多行字符串 + `options: .ignoreUnknownCharacters`）；新暴露 `redundantThrows`（`failures()` 里已无 `try`） |
| `1d21677` | ✅ Lint + ✅ SwiftPM tests（CatVodCore / CatVodSource 的 6 个包全绿，含本轮新增的两组 EPG 单测） | 去掉多余 `throws`；同口径让 `RoutingRecorder.send` 的 `throws` 名副其实（未配置地址直接抛）。双端未签名构建在同一 run 里随后跑，本文件按「Lint/单测已绿」记录 |

本轮踩到的三类坑（裸 `catch`、十六进制大小写、`throws` 冗余）与那次「脚本改坏文件」都已固化进本地检查器：
`Tools/out/syntax_scan.py` 现在查方括号/圆括号配对 + 六类格式器口径（hex 大写、裸 `catch`、条件里的 `&&`、
区间空格、`MARK` 空行、`redundantThrows`），`Tools/out/format_check.py` 认得 Swift 多行字符串。
`redundantThrows` 那条在改前就把 CI 报的两处（`:119`、`:183`）都找了出来，行号一致。

