# M06a 本地 HTTP 服务与本地代理

- 状态：待 CI 验证
- 时间：2026-10-07
- 范围：M6 第一步 —— 本机回环 HTTP 服务 + 播放侧 `/proxy`（header 注入与 Range 透传），以及网络规则内核（proxy 的 hosts 匹配、代理地址解析与规则选择）
- 前置：M05a/M05b（解析链）

## 一、产出

| 件 | 说明 |
| --- | --- |
| `CatVodCore/Vod/Network/HostRuleMatcher.swift` | host 规则匹配：`*` / 子串 / **整串**正则，复刻 `Util.containOrMatch`；`proxy[].hosts`、`headers[].host`、`rules[].hosts` 三处共用 |
| `CatVodCore/Vod/Network/ProxyEndpoint.swift` | 代理地址解析（`http*`→HTTP、`socks*`→SOCKS、`userInfo` 拆账号密码），对照 `bean.Proxy.isValid/isScheme` |
| `CatVodCore/Vod/Network/ProxyRuleResolver.swift` | 代理规则选择：**非通配优先 + 稳定排序**、本地地址直连，对照 `OkProxySelector.select` |
| `CatVodCore/Vod/Network/LocalProxyURLBuilder.swift` | `/proxy` 端点契约与参数编解码（`url` + base64(JSON) 的 header 表） |
| `CatVodCore/Vod/Network/ProxyForwardingPolicy.swift` | header 转发策略：逐跳剥离、请求/响应白名单、CORS、大小写不敏感的覆盖 |
| `CatVodNet/Local/LocalHTTPServer.swift` | 回环服务：9978–9998 扫端口、只绑 `127.0.0.1`、启停幂等，对照 `Server.start()` |
| `CatVodNet/Local/LocalProxyHandler.swift` | 根处理器：`/proxy`、`/health`、`/` 前缀分流，对照 `Process.isRequest` |
| `CatVodNet/Local/LocalProxyRequestDecoder.swift` | 请求还原：query 形态（播放器）与 POST JSON 形态（header 多时） |
| `CatVodNet/Local/LocalProxyUpstreamClient.swift` | 走既有 `HTTPTransport` 取上游（自带默认 UA、`headers[]` 注入、`ads[]` 拦截）+ 体积上限 |
| `CatVodError.localServer(reason:)` | 新增统一错误 case（本机服务不可用时给 UI 可读原因） |
| `ThirdParty/flyingfox.lock.json` | 依赖锁定留痕（FlyingFox 0.27.1 / MIT / exact pin） |

## 二、逐条对齐

| 上游 | 本项目 |
| --- | --- |
| `Server.start()` 从 9978 起扫到 9998 找可用端口，成功后 `Proxy.set(port)` | `LocalHTTPServer.Configuration.portRange = 9978 ... 9998`；`start()` 返回端口且**幂等** |
| `Nano` + `Process.isRequest(url.startsWith("/proxy"))` 用**路径前缀**分流 | `LocalProxyHandler.route(forPath:)` 同样按前缀分流；未识别路径抛 `HTTPUnhandledError` 由 FlyingFox 转 404 |
| `Proxy.doResponse` 转发上游并回 chunked 响应，`ProxyRangeResponsePolicy` 标记 Range 起点 | 回缓冲实体（不伪造 chunked），`206` / `Content-Range` / `Accept-Ranges` 原样回传 |
| `OkProxySelector.select`：`127.0.0.1`/`localhost` 放行 → 规则按「非通配优先」排序 → 首条 `hosts` 命中生效 | `ProxyRuleResolver.selection(forHost:)` 同一顺序（额外放行 `::1`，已注明） |
| `bean.Proxy.create`：`scheme.startsWith("http")`→HTTP、`startsWith("socks")`→SOCKS，`port > 0` 才有效 | `ProxyEndpoint.init?(url:)`（缺端口/越界/未知协议一律丢弃） |
| `Util.containOrMatch(text, regex)` = `text.contains(regex) \|\| text.matches(regex)` | `HostRuleMatcher.matches(text:rule:)`；正则非法时与上游一样退化为「不命中」 |
| 播放接入要求：header 必须覆盖主清单、子清单、分片、密钥与字幕请求 | `/proxy?url=…&h=…` 端点 + `ProxyForwardingPolicy` 白名单透传与注入覆盖 |
| `WebSniffHeaders.forPage`（页面请求要去掉播放器 UA） | 属 Web 嗅探，本轮记入「明确未做」交给 M5c |

## 三、明确未做

1. **播放器接线**：本轮只交付服务与编码器，让 `PlaybackView`/`SpiderEpisodePlaybackView` 真的走 `/proxy`
   属 M06b —— 避免把 UI/播放器改动与网络内核混在一个提交里，出问题难定位。
2. **流式转发**：现在是一次性缓冲；超过 32MB 的响应会 502 并写明原因（HLS 分片/密钥/清单足够用）。
   M06b 起改为「落地临时文件 + `HTTPBodySequence(file:range:)`」。
3. **代理真正生效**（`connectionProxyDictionary` 走 HTTP/SOCKS + 认证）：本轮只做**选择内核**与地址解析；
   会话池与 `URLSession` 委托认证属 M06b。
4. `doh` 解析与 `hosts` 覆盖：M06b。
5. `hlsRules`/`ads` 的 m3u8 改写（上游 `M3u8.java`）：M06c。
6. **只监听 `127.0.0.1`**：上游为投屏监听全网卡，本项目暂不暴露（本服务会替播放器带站点 header，
   绝不能对局域网开放）；投屏属 M9+。

## 四、验收

- 单测：`CatVodCoreTests` 新增 4 个套件（host 规则、代理选择、地址编解码、header 策略）；
  `CatVodNetTests` 新增 3 个文件，其中 `LocalHTTPServerTests` **真的起服务**并用 `URLSession` 打过去：
  `/health` 就绪、header 注入生效、Range 206 与 `Content-Range`、400/404/502、端口回退与重复 `start()` 幂等。
- CI：Lint + SwiftPM tests（含确认 FlyingFox 依赖能解析）+ iOS/macOS 未签名构建。
- 人工（需真机/Mac，M06b 完成后）：播放一个必须带 `Referer` 的 HLS 源能出画面而不是 403。

## 五、回滚

删除 `Packages/CatVodCore/Sources/CatVodCore/Vod/Network/`、`Packages/CatVodNet/Sources/CatVodNet/Local/`
与对应测试文件，再去掉 `CatVodNet/Package.swift` 的 FlyingFox 依赖、`ThirdParty/flyingfox.lock.json`
与 `CatVodError.localServer` 即可；不影响 M05 解析链。

## 六、验证记录

（CI 结果待补：本机没有 Swift 工具链，编译与单测由 CI 判定。）
