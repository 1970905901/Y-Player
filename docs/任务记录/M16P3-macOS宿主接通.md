# M16P3 macOS 宿主接通（js2p 真正可用）

- 状态：**P3a + P3b 均已实现**（宿主会话层 → 站点客户端分发 → 界面接线），随 CI 验证；
  仍需**手工验收**（在 macOS 上真正点一遍，见第六节）
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
| iOS | ~~**不可用**：需要 nodejs-mobile 的 libnode 产物（M1.6 清单第 1–4 项，尚未接入）。`start()` 抛 `runtimeUnavailable`，界面必须显示原因而不是「站点为空」~~ → **已由 M16P4 取代**：libnode 随包内嵌，iOS 走 `NodeMobileRuntime`（就绪解析/超时/早退与 macOS 同一套），真机第 1–4 项通过 |

## 四、P3b 交付（站点分发 + 界面接线）

| 改动 | 内容 |
| --- | --- |
| `CatVodSource/Client/SiteClient.swift` | **站点客户端门面**：按 `Site.kind` 分发 —— CMS（`type 0/1/2/4`）走 `CMSClient`，`type 3` 且 `api` 含 `/spider/` 走 `CatSpiderHTTPClient`；JAR/Python/API 形态不对的站点**在发请求之前**就抛 `unsupported` |
| `Site.availability` 改为 public | 门面、界面、日志必须展示**同一句**原因，不允许两处各写一套文案 |
| `DetailProvider` / `ChangeSourceService` | 客户端类型从 `CMSClient` 换成 `SiteClient`：CMS 行为不变，js2p 站点从此也能看详情、也能参与换源 |
| `AppModel` | 宿主生命周期（`refreshHost` / `restartHost` / `stopHost` / `hostDiagnostics`）+ 发布 `hostStatus`/`hostSites`；`sites`/`allSites` 在 JS 源时改用宿主站点；删掉「等 M1.6」的播放提示 |
| `JS2PHostStatus`（UI） | 状态机：`idle` / `unavailable`（平台不支持）/ `starting` / `running`（baseURL + 站点数 + 被禁用数）/ `failed`，并给出一句话 `summary` |
| `HomeView` / `SearchView` | `cmsSites` → `browsableSites`（不再过滤 `type=3`）：首页与搜索现在都能用 js2p 站点；空态提示改为显示真实宿主状态 |
| `InterfaceManagementView` | 新增「Node 宿主」区块：状态、**重启宿主**、**查看宿主输出**（诊断） |
| `SpiderEpisodePlaybackView`（UI，新文件） | Spider 站点的**播放入口**：`POST /play {flag, id}` 换地址后再进 `PlaybackView`；失败给可读原因。单开一层的原因：这一步是异步的，塞不进同步的 `@ViewBuilder` 目标 |
| `VodDetailView` / `+Data` | 选集目标改为三分支（直链 → Spider → 说明原因）；选集行的警告图标不再对可播放的 Spider 集误报；不可播放原因改用 `Site.availability` 的统一文案 |

## 五、已知小瑕疵（如实记录，未修）

**无参数请求的 URL 会带一个尾随 `?`**：`ApiRequestFactory.getRequest` 对空参数也设置了
`components.queryItems`（设为 `[]`），于是 `URLComponents.url` 渲染成 `.../provide/vod?`。
这是纯观感问题（上游正常忽略），但为了不改动 M01 已验证的组装层，暂不处理；
`SiteClientDispatchTests` 因此按 `host` / `path` / 「参数为空」断言，而不是整串比较。

## 六、手工验收（需要 macOS，尚未执行）

1. `brew install node`（或设 `YPLAYER_NODE=/path/to/node`）；
2. 接口地址填 `https://9280.kstore.vip/ceshi/index.js` → 加载；
3. 期望：
   - 「接口管理 → Node 宿主」显示 `宿主运行中：http://127.0.0.1:9988，站点 85 个…`；
   - 站点清单出现约 **85** 个站点，`api` 形如 `http://127.0.0.1:<port>/spider/<spiderKey>/<type>`；
   - 首页/搜索能选到这些站点并返回内容（走 CatSpider HTTP 协议）；
   - 进详情、选一集 → 应短暂显示「正在向站点请求播放地址…」后开始播放（走 `POST /play`）；
5. 反向用例（每一项都必须给出可读原因，不能静默失败）：
   - 把 `YPLAYER_NODE` 指向不存在的路径 → 「未找到 node 可执行文件」；
   - 宿主未启动时点选播放 → 播放页显示宿主不可用原因，而不是空白或一直转圈；
   - `csp_*.jar` 站点：选集行显示警告图标，进入后说明「需要 JVM，Apple 平台不支持」；
6. iOS 侧：应显示「内嵌 Node 宿主不可用：iOS 需要 libnode…」，同样不能显示成「暂无站点」。
