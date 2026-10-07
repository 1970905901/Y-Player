# M05c Web 嗅探与聚合解析（第一阶段：规则、计划、JSON 侧竞速）

- 状态：第一、二阶段均已完成并推送（CI 结果见「验证记录」）
- 时间：2026-10-07
- 范围：M5 第三步 —— `type=0`（Web 嗅探）与 `type=4`（聚合解析）里**与平台无关**的全部判定与调度
- 前置：M5a（解析链契约）、M5b（`type=1` JSON 解析）、M6a（本地 `/proxy`：Web 嗅探拿到的地址同样需要注入 header）

## 一、为什么先做「不碰 WebView」的那一半

上游的 `type=0` 靠 Android `WebViewClient.shouldInterceptRequest` **拦截每一个子请求**，
`type=4` 靠 `CountDownLatch` 并发跑多个解析器。Android 的「拦截所有请求」在 Apple 平台没有等价 API
（`WKURLSchemeHandler` 只对自定义 scheme 生效、`decidePolicyFor` 只看主框架导航），
但**要不要把某条 URL 当成播放地址**这件事本身与平台无关 —— 它就是 `Sniffer.isVideoFormat` 的一组规则。

所以本阶段把「判定 + 计划 + JSON 侧竞速」全部落到可单测的纯 Swift 里，
第二阶段只写一层 WebKit 适配（JS 注入 + 导航回调 + 消息通道），
把「真实浏览器行为」之外的逻辑风险提前消掉。

## 二、产出

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Parse/SniffRules.swift` | 嗅探规则引擎：`rule(forURL:)`（host 匹配文本 = URL host + `url` 查询参数 host）、`scripts(forURL:)`、`isVideoFormat` / `decision(forURL:)`（`exclude` → `regex` → `url=http`/`v=http`/`.html` → 默认媒体正则 `SNIFFER`）、`isAd(host:)`、`isPlayerPage`、`mediaURL(inText:)`（`AI_PUSH` 抽取）、`firstMediaURL(inText:)`；`SniffDecision` 把「是不是媒体 + 为什么」放在一起 |
| `CatVodCore/Vod/Parse/SniffedPageList.swift` | 播放页去重与上限（上游 `CustomWebView.addUrl`：超 `MAX_URLS` 先清空） |
| `CatVodCore/Vod/Parse/WebSniffHeaders.swift` | 解析页 header 收敛（上游 `WebSniffHeaders.forPage`）：媒体 UA 丢弃、必要时回填浏览器 UA（去掉 `; wv)`、` Version/4.0`） |
| `CatVodCore/Vod/Parse/ParsePageHTML.swift` | 聚合解析页（等价上游 `assets/parse.html`）：每个 `type=0` 一个 iframe；**离开本机 HTTP 服务**，直接 `loadHTMLString`，并对地址做 JS 转义 |
| `CatVodCore/Vod/Parse/AggregateParsePlan.swift` | `type=4` 计划：按 `flag` 分 `type=1` / `type=0` 两组、`taskCount`（`json.count + (web.isEmpty ? 0 : 1)`）、`webSniffQuery`、`jsonJobs(...)` |
| `CatVodCore/Vod/Parse/ParseJob.swift` | `Origin` 新增 `.aggregateMember`（聚合成员的来源可读） |
| `CatVodSource/Parse/AggregateParser.swift` | JSON 侧执行器：并发跑成员、**谁先给出合法地址算谁**、单成员失败不致命、全失败时把所有原因带回 |
| 单测 | `CatVodCoreTests/{SniffRulesTests,SniffedPageListTests,WebSniffHeadersTests,AggregateParsePlanTests}`、`CatVodSourceTests/AggregateParserTests` |

## 三、逐条对齐（上游 → 本仓库）

| 上游 | 本仓库 |
| --- | --- |
| `Sniffer.getRule(Uri)`：`TextUtils.join(",", host(uri), host(url 参数))` 后 `Util.containOrMatch` | `SniffRules.hostMatchText(for:)` + ``HostRuleMatcher``（M6a 已复刻 `containOrMatch` 的「包含 / 整串正则 / `*`」） |
| `Sniffer.isVideoFormat`：exclude → regex → `url=http`/`v=http`/`.html` → `SNIFFER` | `SniffRules.decision(forURL:)`（顺序一字不改，另附可读原因） |
| `Sniffer.getUrl`：JSON 对象或含 `$` 原样返回，否则 `AI_PUSH` 首个匹配 | `SniffRules.mediaURL(inText:)` |
| `CustomWebView.isAd` / `PLAYER` / `addUrl` | `SniffRules.isAd(host:)` / `isPlayerPage` / `SniffedPageList` |
| `WebSniffHeaders.forPage` | `WebSniffHeaders.forPage(headers:fallbackUserAgent:)` |
| `ParseJob.superParse`：`getParses(1,flag)` 并发 + `getParses(0,flag)` 合并成一个 WebView | `AggregateParsePlan` + ``AggregateParser``（JSON 侧）；Web 侧留给第二阶段 |
| `ParseJob.jsonParse(item, webUrl, fatal=false)` / `checkResult`（URL 长度 > 40） | ``AggregateParser`` 复用 ``JSONParser``（M5b 已含 40 字符判定） |
| `assets/parse.html` + `server/process/Parse.java` | ``ParsePageHTML``（含 JS 转义；不再需要 `/parse` 这个本机路由） |

## 四、设计取舍

1. **判定与执行分离**：`SniffRules` 是纯函数集合，`AggregateParser` 只吃 `ParseJob`；
   Web 侧（第二阶段）与 JSON 侧共用同一份判定，避免「两边判定不一致」这类最难查的 bug。
2. **失败不静默**：`decision(forURL:)` 返回原因、`AggregateParser` 全失败时列出每个成员的原因
   （上游只回调一次 `onParseError`，用户不知道是哪个解析器挂了）。
3. **不引本机服务**：上游把解析页放在 `/parse` 路由上（因为 Android 只能这样给 WebView 地址）；
   Apple 侧 `loadHTMLString` 直接可用，少一个可被外部访问的端点（更少的攻击面）。
4. **非法正则退化为「不命中」**：上游会抛 `PatternSyntaxException` 被上层吞掉；
   这里显式退化并在文档里写明，避免规则写错时表现为「整页嗅探不到」而无线索。

## 五、第二阶段：WebKit 载体与播放侧接线（已完成）

| 件 | 说明 |
| --- | --- |
| `CatVodUI/WebSniffSession.swift` | `@MainActor` 的 `WKWebView` 嗅探会话。三条通道合起来逼近 Android 的「拦截每个子请求」：① **导航回调**（每次导航当候选地址，带该请求的 header）② **注入 JS**（包 `XMLHttpRequest.open` / `window.fetch` / `HTMLMediaElement.src`，经 `WKScriptMessageHandler` 上报）③ **页面加载完**扫 `<video>/<audio>/<source>/<iframe>` 并顺序执行规则脚本。广告 host 直接 `cancel`；命中 `PLAYER` 再开一层（`SniffedPageList` 去重、内层 `detect=false`）；`/cdn-cgi/challenge-platform/` 把人机验证页面**显示出来**让用户自己过（上游此时弹对话框） |
| `CatVodUI/WebSniffWebView.swift` | `UIViewRepresentable` / `NSViewRepresentable` 双端承载：平时缩到 1pt（WebKit 对不在视图层级里的 WebView 会降频，必须挂在层级上），人机验证时放大到 320pt |
| `CatVodUI/ParsePlaybackView.swift` | 按 `type` 分派三条通道：`type=1` JSON、`type=0` 单页嗅探、`type=4` JSON 并发 + Web 并行（**谁先成功算谁**）；两条通道都失败才给结论，并把两边原因合并展示 |

平台差异（已在代码里逐条注明，不藏在实现里）：
- Apple 侧看不到「图片 / 普通脚本」这类子请求 —— 它们本来也不会通过媒体判定，实际影响有限；
- 内层播放页的 WebView 不进视图层级（iOS 可能降频）；
- `WKURLSchemeHandler` 只对自定义 scheme 生效，所以**不能**照搬上游「拦截一切请求」的写法。

## 六、仍未做

1. `type=2/3`（JAR）在 Apple 平台仍不可用（与 M5a 结论一致）。
2. `parse/jx = 1` 的第二层解析：等真实源验证过「Web 嗅探返回完整 `Result`」再启用第二层。
3. 内层播放页的可视化（上游为它弹独立窗口）：目前只在后台跑；若真机发现某些源必须在**可见**窗口里才播，再补可见子窗口。

## 七、验证记录

### 2026-10-07 · 本轮 CI（Windows 上无 Swift 工具链，编译/格式问题只能靠 CI 发现）

| 提交 | 作业 | 结果 | 具体错误 → 修复 |
| --- | --- | --- | --- |
| `2ee7fed`（第一阶段） | SwiftPM | ❌ | `#expect(list.insert(x))`：宏参数里不能调 `mutating` 方法（`'$0' is immutable`）→ 先取局部变量再断言 |
| `2ee7fed` | Lint | ❌ | `return .parsed(try await …)`（`hoistTry`/`hoistAwait`）、`public init() {}`（`emptyBraces`）→ 均已修 |
| `dbc8e5b`（第二阶段） | Lint | ❌ | 空 `update*` 实现要写 `{ }`、多行 `if` 的 `{` 要单独一行、逃逸闭包去掉冗余 `self.` → 均已修 |
| `dbc8e5b` | SwiftPM | ❌ | `AggregateParserTests` 缺 `@testable import CatVodSource`（`cannot find 'AggregateParser' in scope`）→ 已补并按字母序排好 |
| `b2a3f58` | Lint | ✅ | — |
| `b2a3f58` | SwiftPM | ❌ | 断言写错：默认媒体正则 `(?:\?.*)?` 是**贪婪**的（会把 `"></video>` 一起吞掉，与上游一致）→ 断言改成「以该地址开头」，另补一个干净用例 |

结论与状态：以 **Actions 里最新一条提交**为准（本文件会随每次修复更新）。
本轮踩到的 9 类坑（含 `private(set)` 跨文件、`read<T>` 双可选、FlyingFox 同名类型等）已写进
`docs/构建与分发.md` 的「已知的构建陷阱」8–16，并让 `Tools/out/check_swift.py` 覆盖其中两类（空实现 `{}`、行长等）。

自动化验证：`SniffRulesTests`、`SniffedPageListTests`、`WebSniffHeadersTests`、`AggregateParsePlanTests`、
`AggregateParserTests`（另加既有 114 个测试）在同一次 SwiftPM 运行里执行。

人工清单（需 Mac / 真机）：
1. `type=1` 的集：解析后进播放页；失败给可读原因（缺名解析器 / 地址过短 / 非 2xx / 不是 JSON）。
2. `type=0` 的集：先看到「正在用解析页嗅探真实地址…」，页面加载后进播放页；
   站点要求人机验证时，页面会**展开**给用户操作（上游此时弹对话框）。
3. `type=4` 的集：JSON 侧并发与 Web 侧并行，**谁先成功算谁**；两条都失败时原因合并展示。
