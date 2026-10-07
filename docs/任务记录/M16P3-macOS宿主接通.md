# M16P3 macOS 宿主接通（js2p 真正可用）

- 状态：**P3a 完成**（宿主会话层 + 单测，随 CI 验证）；**P3b 待做**（站点客户端分发 + 界面接线）
- 依赖：M16P1（`NodeRuntimeAdapter`）、M16P2（`HostSiteCatalog` 与逐字实测契约）
- 目标：让 js2p 的 `index.js` 从「只是下载到本地」变成「macOS 上真能列出站点、真能浏览」

## 一、为什么拆成 P3a / P3b

| 步骤 | 内容 | 可验证方式 |
| --- | --- | --- |
| **P3a**（本次） | 「本地 bundle → 可用站点清单」的**会话层**：起 Node、等就绪、二次探活、取清单、错误分层 | 单测（用假运行时 + 假传输层，CI 可跑） |
| **P3b**（下一步） | 界面真正用上这些站点：`SiteClient` 按站点类型分发（CMS vs CatSpider HTTP）、`AppModel` 接线、界面文案与状态展示 | 编译（CI）+ 手工点一遍（需要 macOS） |

拆分的理由很实际：P3a 的失败模式全在契约层，能靠单测锁死；
P3b 一旦把 UI 与 `CatVodNode` 混进同一次提交，出问题只能靠 20 分钟一轮的 CI 猜。

## 二、P3a 交付

| 文件 | 内容 |
| --- | --- |
| `Packages/CatVodNode/Sources/CatVodNode/NodeRuntimeLaunching.swift` | 宿主运行时协议（`start`/`stop`/`recentOutput`），`NodeRuntimeAdapter` 一行扩展即满足；只为让上层能在单测里替换进程启动 |
| `Packages/CatVodSource/Sources/CatVodSource/Host/JS2PHostService.swift` | 宿主会话：`start(forceRestart:)`（幂等）、`sites(forceRestartHost:)`、`health()`、`recentOutput(limit:)`、`stop()`、`currentBaseURL()` |
| `Packages/CatVodSource/Sources/CatVodSource/Host/JS2PHostError.swift` | 会话层错误（`runtimeUnavailable` / `hostNotReady` / `sitesUnavailable`），均带可读原因 |
| `Packages/CatVodSource/Package.swift` | 新增 `CatVodNode` 依赖（主 target 与测试 target）——包注释本来就写着「js2p 宿主与 JS 运行时」，这正是它该待的地方 |
| `Packages/CatVodSource/Tests/CatVodSourceTests/JS2PHostServiceTests.swift` | 7 个用例（见下） |

### 关键设计决策

1. **就绪行 ≠ 可用，必须二次探活。** 实测里 bundle 先拉远端配置、期间已在监听；
   `GET /health` 才是应用层可用的证据。不探活就会把「配置没加载完」误报成「站点为空」。
2. **幂等启动。** `start()` 已就绪就直接返回缓存的 baseURL；`forceRestart: true` 才先停再起
   （用户点「重启宿主」）。避免每次进页面都拉起一个 node 进程。
3. **不自己探测端口。** 契约规定 `EADDRINUSE` 时 bundle 自行 +1 重试，就绪行给的是**实际**端口 ——
   宿主去猜端口只会引入竞态。
4. **错误必须带诊断。** 会话层错误会把宿主最近 6 行输出附在消息里：
   bundle 的报错通常就在里面，不附等于让用户盲猜「为什么没有站点」。
5. **协议只暴露三件事。** 不把 `NodeRuntimeAdapter.Status` 搬进协议 —— 协议里出现具体类型，
   测试替身就会被拖进实现细节。

### 单测覆盖

| 用例 | 断言 |
| --- | --- |
| `loadsSites` | 站点数、相对 `api` 补全为 `http://127.0.0.1:9988/spider/douban/3`、绝对 `api` 原样、请求顺序为 `/health` → `/full-config`、只启动一次 |
| `startIsIdempotent` | 连续两次取站点只 `start` 一次、不 `stop` |
| `forceRestart` | `start=2`、`stop=1` |
| `healthGate` | 就绪行出现但 `{"ok":false}` → `hostNotReady`，消息含 `GET /health` 与宿主输出；`currentBaseURL` 仍为 nil |
| `launchFailure` | 启动失败 → `runtimeUnavailable`，消息含原因与最近输出 |
| `sitesFailure` | `/full-config` 500 → `sitesUnavailable` |
| `stopAndRestart` | `stop()` 后 `currentBaseURL` 为 nil、`health()` 为 false，可再次启动 |

## 三、平台现状（如实说明）

| 平台 | 现状 |
| --- | --- |
| macOS | 有实现：随包 `Resources/node/node`、环境变量 `YPLAYER_NODE`、或 Homebrew/系统路径 |
| iOS | **不可用**：需要 nodejs-mobile 的 libnode 产物（M1.6 清单第 1–4 项，尚未接入）。`start()` 抛 `runtimeUnavailable`，界面必须显示原因而不是「站点为空」 |

## 四、P3b 计划（下一步）

1. **`SiteClient` 分发**：按 `Site.kind` 选择客户端 —— CMS 站点走 `CMSClient`，
   `type 3`（CatSpider HTTP）走 `CatSpiderHTTPClient`（已实现且有单测，缺的只是接线）；
2. **`AppModel` 接线**：当前接口是 JS 源时创建 `JS2PHostService`、把宿主站点写入 `allSites`/`sites`，
   并在接口页展示宿主状态（端口、是否探活、最近输出、重启/停止按钮）；
3. **文案替换**：把「JS 源待内嵌 Node 服务就绪（M1.6 落地）」这类占位提示换成真实状态
   （macOS 显示宿主状态；iOS 显示「需要 libnode，仅 macOS 支持」）；
4. **手工验收**（需要 macOS）：
   - `brew install node`（或设 `YPLAYER_NODE=/path/to/node`）；
   - 接口地址填 `https://9280.kstore.vip/ceshi/index.js` → 加载；
   - 期望：状态显示宿主端口（形如 9988）、站点清单出现约 **85** 个站点、`api` 为
     `http://127.0.0.1:<port>/spider/<spiderKey>/<type>`；
   - 反向用例：把 `YPLAYER_NODE` 指向不存在的路径 → 必须给出「未找到 node 可执行文件」而不是「站点为空」。
