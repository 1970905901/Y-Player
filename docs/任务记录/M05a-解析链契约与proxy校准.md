# M05a 解析链契约 + `proxy:` 前缀校准

- 状态：CI 已通过（2026-10-07，随 `aad4160` / `02877ac` 验证；见 `M05b-type1-JSON解析.md` 的「验证记录」）
- 时间：2026-10-07
- 范围：M5 的**第一步**——把解析链的协议事实固化成可单测的契约，并把 M01 留下的「`proxy:` 等前缀待校准」结清
- 前置：M02P11（`0ba3026` / `e8d3bbf`，Tab 与设置/追剧页）

## 一、校准依据（第一次有了上游源码）

M01 写的是「`proxy:` 等 playUrl 前缀待 M5 用 `ParseJob.java` 校准」，但仓库里没有上游源码。
本次用 GitHub API 取到参考实现（`webhtv/webhtv`，即本仓库文档里说的 webhtv/FongMi 系）并逐行核对：

| 文件 | 关键结论 |
| --- | --- |
| `app/src/main/java/com/fongmi/android/tv/player/ParseJob.java` | `setParse()`：`json:{url}` → 临时 `type=1`；`parse:{name}` → `VodConfig.getParse(name)`；**都不是**且解析器为空 → `Parse(0, result.playUrl)`（把 playUrl 当 Web 页）。**没有任何 `proxy:` 分支** |
| 同上 `doInBackground()` | 按 `type` 分派：0 → WebView 嗅探；1 → `jsonParse`；2 → JAR `Json`；3 → JAR `Mix`；4 → 聚合（并发所有匹配 flag 的 type=1 + 一个把所有 type=0 拼起来的 WebView） |
| 同上 `jsonParse()` | `GET item.url + webUrl`，读 `url`，为空读 `data.url`；`checkResult`：**长度 > 40** 才成功；响应里的 UA/Referer/Cookie/ua 会覆盖 header，取不到才回落 `parse.header` |
| `bean/Parse.java` | `isEmpty()` = `type == 0 && url.isEmpty()`；`setHeader()` **只在自身 `ext.header` 为空时**套用结果 header；`ext` 只含 `flag`/`header` |
| `player/ParseJob.java#getClick` | 站点 `click` 优先，其次结果 `click` |
| `Constant.java` | `TIMEOUT_PARSE_DEF` / `TIMEOUT_PARSE_WEB` = 15s，`TIMEOUT_PARSE_LIVE` = 10s |
| `server/process/Proxy.java`、`catvod/.../OkProxySelector.java`、`quickjs/.../Spider.java` | `proxy` 出现在**网络代理**与**本地服务**（`/proxy` 端点、`ProxyRule`、`getProxies()`）里，与 playUrl 前缀无关 |

**结论：`proxy:` 不是解析链的 playUrl 前缀。** 上游解析链只有 `json:` / `parse:` / 裸地址三种；
`proxy:` 属于网络代理规则（`SourceConfig.proxy` → `ProxyRule`）与 M6 的本地 `/proxy` 服务。
矩阵里那行「❓ 待校准」据此结清（并写明结论，避免下次又被当成未知项）。

## 二、本次产出（`CatVodCore`，纯 Swift、可 CI 单测）

| 件 | 说明 |
| --- | --- |
| `Vod/Parse/ParseJob.swift` | 解析任务：选中的解析器 + `webURL` + `flag` + 结果 header + `click` + 超时 + **来源**（`json:` 前缀 / 具名解析器 / 裸地址 / 站点级前缀 / 默认解析器）；`effectiveHeaders`（解析器 `ext.header` 优先）、`acceptsFlag`、`availability` |
| `Vod/Parse/ParseJobResolver.swift` | `ParseContext`（11 个字段、全默认值）+ `ParseJobError`（每类都给中文 `reason`）+ `resolve()`（**逐条复刻 `setParse` 的顺序**）+ `followUp()`（解析结果仍需解析时，用默认解析链对结果地址再排一次） |
| `Vod/Parse/ParseResultValidator.swift` | `type=1` 取址（`url` → `data.url`）、成功判定（长度 > 40）、响应 header 提取（只认 `ua`/`User-Agent`/`Referer`/`Cookie`，取不到回落）、继续解析判定 |
| `PlayUrlPrefix.prefixedInstruction(_:)` | 新增：**只看前缀**（裸地址返回 `nil`）。没有它就无法复刻上游「裸地址不覆盖已选解析器」这条顺序 |
| 单测 | `ParseJobResolverTests`（12 例）+ `ParseResultValidatorTests`（4 例） |

刻意与上游不同的**一处**（已写进代码注释）：`parse:{名字}` 在配置里找不到解析器时，上游会退化成
「把 `parse:名字` 当成 Web 解析页地址」从而得到一个莫名其妙的失败；我们直接抛
`parserNotFound(name:)`，文案是「接口里没有名为「X」的解析器」。属于**更可诊断**的偏差，不是协议不一致。

## 三、明确未做（留给 M5b / M5c）

1. ~~**`type=1` 的真实请求**（M5b）~~ → 已在 **M05b** 完成（`JSONParser` + `ParsePlaybackView`，含 9 例单测）。
2. **`type=0` Web 嗅探**（M5c）：需要 M6a 的本地 `/proxy` + 完整 header 透传，以及平台 WebKit 承载层。
3. **`type=2/3` JAR 解析**：Apple 平台无 JVM，永久不支持（`ParseJobResolver` 会直接给出原因）。
4. **`type=4` 聚合的并发执行**：契约里能识别（`ParserKind.aggregate`），执行属 M5c（含「谁先成功算谁」）。
5. ~~**界面接线**~~ → 已在 **M05b** 完成（详情页里需要解析的集走 ``ParsePlaybackView``）。

## 四、验收

- 单测覆盖：前缀选择顺序、默认解析器与裸地址的相对优先级、站点级回退、缺名解析器、JAR 拒绝、
  超时（默认 15 可覆盖）、`followUp` 两条路径、40/41 长度边界、`url`/`data.url` 取址、header 提取与回落。
- CI：`CatVodCore tests`（新增两个测试文件）+ 其余包构建与双端未签名构建。
- 人工：无需（本次是纯契约与纯函数，等 M5b 接上真实请求后再做端到端）。

## 五、回滚

删除 `Packages/CatVodCore/Sources/CatVodCore/Vod/Parse/`（3 个文件）、两个测试文件与
`PlayUrlPrefix.prefixedInstruction`，并把矩阵/M01 的两行状态改回「待校准」即可；不影响既有链路。
