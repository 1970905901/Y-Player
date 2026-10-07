# M05b `type=1` JSON 解析执行

- 状态：CI 已通过（2026-10-07，见文末「验证记录」）
- 时间：2026-10-07
- 范围：M5 第二步 —— 让 `type=1`（JSON）解析器**真的能跑**：发请求 → 取值 → 校验 → 产出可播放地址，并接进详情页
- 前置：M05a（`ParseJob` 契约 + `proxy:` 校准）

## 一、产出

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Parse/ParsedPlayback.swift` | 解析成功的产物：`url` + `headers` + `from`（来源解析器名）。`type=1` 与将来的 `type=0` Web 嗅探共用它，调用方不区分通道 |
| `CatVodSource/Parse/JSONParser.swift` | `type=1` 执行器：`GET 解析器地址 + webUrl`，读 `url`（为空读 `data.url`），按 `> 40` 判定成功，响应 header 只认 UA/Referer/Cookie/ua（取不到回落） |
| `CatVodSourceTests/JSONParserTests.swift` | 10 例单测（含一个记录**完整请求**的假传输层，用来断言 header 与超时） |
| `CatVodUI/ParsePlaybackView.swift` | **界面接线**：详情页里「需要解析」的集先解析再进播放页；解析失败/未实现的类型（type=0/4、JAR）给出可读原因 |
| `VodDetailView` / `+Data` | 新增 `canParse(_:)` / `showsUnsupportedBadge(for:)`；`destination(for:at:)` 增加解析分支；直链与 Spider 分支不变 |

**错误模型**：全部抛 `CatVodError`（仓库既有约定里的「面向 UI 的统一错误」），不返回半成品：

| 情况 | 抛出的 case |
| --- | --- |
| 解析器不可用（JAR/未知类型） | `unsupported(feature: "解析器「X」", reason: "需要 JVM…")` |
| 不是 `type=1`（例如 type=0 Web） | `unsupported(feature: "type=0 解析", reason: "…属 M5c")` |
| 解析地址构不成 URL | `parseFailed` |
| 非 2xx | `network(status:url:reason:)` |
| 响应不是合法 JSON | `decoding(path: "parse.X", reason: "响应不是合法 JSON：…")` |
| 取到的地址为空 / 长度 ≤ 40 | `parseFailed`（把长度写进 reason，便于对着源排查） |

## 二、逐条对齐（`ParseJob.jsonParse`）

| 上游 | 本项目 |
| --- | --- |
| `OkHttp.newCall(item.getUrl() + webUrl, item.getHeader())` | 请求地址 = `parser.url + webUrl`；header = `job.effectiveHeaders`（解析器 `ext.header` 优先）；超时 = `job.timeout`（默认 15s） |
| `Json.safeString(object, "url")`，为空读 `data.url` | `ParseResultValidator.playURL(fromJSON:)` |
| `url.length() > 40` 才成功 | `ParseResultValidator.isAcceptable(_:)`（`ParserOutcome.minimumJSONURLCount = 41`） |
| `getHeader(object)`：只认 UA/Referer/Cookie/ua | `ParseResultValidator.headers(fromJSON:fallback:)`（大小写不敏感，取到就不回落） |

## 三、明确未做

1. **`type=0` Web 嗅探（M5c）**：需要 M6a 的本地 `/proxy` 与平台 WebKit 承载层。
2. **`type=4` 聚合**：并发所有匹配 flag 的 `type=1` + 一个把 `type=0` 拼起来的 WebView，属 M5c。
3. **`type=2/3` JAR**：Apple 平台无 JVM，永久不支持（执行器直接给原因）。
4. **`parse/jx = 1` 的第二层解析**：契约已备（`ParseJobResolver.followUp`），但 `type=1` 的响应里没有
   `parse/jx` 字段，上游 `checkResult(headers:url:)` 那条路径也不追第二层；等 M5c 的 Web 嗅探结果
   （是一个完整 `Result`）再启用。

## 四、验收

- 单测：`CatVodSourceTests/JSONParserTests`（10 例：正常取值、`data.url` 回退、过短、空地址、非 2xx、非法 JSON、
  解析器 header 优先、响应 header 覆盖、type=0 与 JAR 拒绝）。
- CI：`CatVodSource tests` + `CatVodUI (build only)` + 双端未签名构建。
- 人工：详情页里「需要解析（parse/jx = 1）」的集点进去应显示「正在解析播放地址…」后进入播放页；
  失败时显示可读原因（缺名解析器 / 地址过短 / 非 2xx / 响应不是 JSON）；`type=0`/`type=4` 的集应显示
  「属 M5c」的说明而不是空白。

## 五、回滚

删除 `ParsedPlayback.swift`、`JSONParser.swift`、`ParsePlaybackView.swift` 与对应测试文件，
并把 `VodDetailView` 的解析分支与 `canParse(_:)`/`showsUnsupportedBadge(for:)` 去掉即可；
不影响 M05a 的契约与既有链路。

## 六、验证记录

### 2026-10-07 · CI（`aad4160` 契约 + 执行、`02877ac` 界面接线，全部通过）

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| `Lint (SwiftLint / SwiftFormat)` | ✅ | 新增 8 个 Swift 文件（4 源 + 4 测试）零违规 |
| `SwiftPM tests` | ✅ | `CatVodCoreTests` 新增 16 例（`ParseJobResolverTests` 12 + `ParseResultValidatorTests` 4）、`CatVodSourceTests` 新增 10 例；`CatVodUI (build only)` 在 macOS 上编译通过（也证明接线代码在 macOS 可编译） |
| `Build apps (unsigned)` | ✅ | iOS 模拟器 + macOS 两端 |
| `Unsigned IPA (sideload artifact)` | ✅ | 侧载用未签名 IPA |

**CI 抓到的真错误（记下来避免复发）**：`ParseJobResolver.resolve` 里的**局部变量 `selection` 与同名静态方法重名**，
Swift 把 `selection(...)` 解析成「调用变量」→ `cannot call value of non-function type 'ParseJobResolver.Selection?'`。
已把方法改名 `select`（`click` 帮手一并改名 `resolvedClick`），并在本机加了一条自检脚本
（`Tools/out/check_shadow.py`：按文件交叉比对 `func` 名与 `let/var/guard let/for` 名）专门抓这类遮蔽。

### 待人工验证（需要 Mac / 真机）

按第四节最后一条：在真实源上点一个 `parse/jx = 1` 的集，看是否能解析后进播放页；
再点一个 `type=0` 的集，确认显示「属 M5c」的说明。
