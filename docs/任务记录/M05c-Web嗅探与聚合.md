# M05c Web 嗅探与聚合解析（第一阶段：规则、计划、JSON 侧竞速）

- 状态：代码与单测已推送（见「验证记录」）；**WebKit 载体与播放侧接线属第二阶段**（下一轮）
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

## 五、明确未做（第二阶段）

1. WebKit 载体：`WKWebView` + 注入 JS（拦截 `fetch`/`XHR`/`MediaSource`）+ 导航回调 + 消息通道，
   把候选地址交给 ``SniffRules`` 判定；`CDN 人机验证`（上游遇到 `/cdn-cgi/challenge-platform/` 时弹窗）需要真人交互，Apple 侧只做提示。
2. `ParsePlaybackView` 的 `type=0` / `type=4` 接线（目前这两类仍显示里程碑说明文案）。
3. `type=2/3`（JAR）在 Apple 平台仍不可用（与 M5a 结论一致）。

## 六、验证记录

（CI 结果与人工清单在第二阶段一并补齐；本阶段的自动化验证是 4 个 Core 套件 + 1 个 Source 套件。）
