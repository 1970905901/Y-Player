# M16P1 Node 宿主适配（宿主侧落地）

- 状态：**已完成并通过 CI**（6 包单测 + Lint + 双端构建全绿）；契约的实测验证见 `M16P2-宿主站点清单实测.md`
- 时间：2026-10-07
- 依赖：M1.5 的宿主契约（`docs/js2p宿主契约.md`，逐字实测）

## 目标与边界

把 js2p 的**宿主契约**从文档变成可执行、可单测的代码。
M1.6 的真正风险在「iOS 侧 libnode 产物」（需 macOS/真机），本步先把宿主侧做完并明确标注平台差异。

- ✅ 已做：`CatVodNode` 包的**宿主侧**全部逻辑（配置、env、就绪解析、进程生命周期、超时/早退、诊断输出）。
- ❌ 未做：iOS 的 libnode（`NodeMobile.start`）；`start()` 在 iOS 上**直接抛 `.runtimeUnavailable`**，不假装可用。
- ❌ 未做：真实 6.29 MB `index.js` 的端到端跑通（需要真 node + 下载 bundle，见下文「下一步」）。

## 契约 → 代码对应

| 契约（实测原文） | 代码 |
| --- | --- |
| `process.env.DEV_HTTP_PORT \|\| process.env.PORT \|\| 9988` | `NodeRuntimeConfiguration.preferredPort` → `DEV_HTTP_PORT` |
| `process.env.HOST \|\| "0.0.0.0"` | `host` 默认 `127.0.0.1` |
| `logger: process.env.NODE_ENV !== "development"` | `suppressBundleLogging` → `NODE_ENV=development` |
| 未设 `CATVOD_DISABLE_AUTOSTART=1` 且未注入 `catServerFactory` 且 `argv[1]` 以 `index.js` 结尾 | `satisfiesAutoStartContract`；env 组装时**移除** `CATVOD_DISABLE_AUTOSTART` |
| `CatVodSpiderios listening on http://127.0.0.1:<实际端口>` | `NodeReadiness.port(fromLine:)` |
| `Port <n> is already in use. Trying next available port...` | `NodeReadiness.isPortConflictLine`（诊断） |
| `Wh.listen({port, host})` / 自增重试 | 由 bundle 自行处理；宿主只解析**实际**端口 |

## 实现

| 件 | 说明 |
| --- | --- |
| `NodeRuntimeConfiguration` | 配置 + `processEnvironment(base:)`（可测，不依赖真实环境） |
| `NodeReadiness` | 就绪行解析（纯函数，容忍前后缀与 `\r`） |
| `NodeRuntimeError` | 六种失败各有可展示描述：`runtimeUnavailable` / `launchFailed` / `readinessTimeout` / `exitedBeforeReady` / `invalidConfiguration` / `stopped` |
| `NodeRuntimeAdapter`（actor） | 状态机：`start()` / `stop()` / `status()` / `recentOutput()`；就绪超时用内部定时器（不用 `TaskGroup`，避免 `CancellationError` 污染调用方） |
| `NodeRuntimeAdapter+Start` | macOS：`Process` + `Pipe`；iOS：抛 `runtimeUnavailable` |
| 可执行文件定位 | `YPLAYER_NODE` 环境变量 → 随包 `Resources/node/node` → Homebrew / 系统路径 |

## 测试（CI 可跑）

- `NodeReadinessTests`：就绪行 / 自增端口 / 前后缀与 `\r` / 非法输入（端口 0、70000、缺数字）。
- `NodeRuntimeConfigurationTests`：env 注入、`CATVOD_DISABLE_AUTOSTART` 被移除、额外 env 覆盖、脚本名大小写不敏感。
- `NodeRuntimeAdapterTests`（仅 macOS）：用 `/bin/sh` 冒充 node 跑**真实进程**——
  - 脚本打印 `...:${DEV_HTTP_PORT:-0}` → 断言 `baseURL` 端口与配置一致（同时验证 env 真的注入了）；
  - 只 sleep 不打印就绪行 → `.readinessTimeout` 且带最近输出；
  - 打印后 `exit 3` → `.exitedBeforeReady(code: 3)`；
  - 脚本名不是 `index.js` → `.invalidConfiguration`，且**不启动进程**。

> 测试里让假脚本叫 `index.js`、可执行文件用 `/bin/sh`：既满足文件名契约，又能真实覆盖「启动 → 读 stdout → 解析 → 收尾」。

## 下一步（M1.6 剩余，需要 macOS）

1. macOS 上跑真 bundle：下载 6.29 MB `index.js` + `.md5` 校验（复用 `SourceRepository` 的 js2p 缓存）→ `YPLAYER_NODE=/opt/homebrew/bin/node` → `start()`；
2. 用 `CatSpiderHTTPClient` 打 `/spider/*` 全链路（`init/home/category/detail/search/play`）；
3. 确定站点清单路由（`/config/sites/list` 等候选）与 `sites[].api` 实际形态；
4. iOS：引入 nodejs-mobile libnode 18.20.4，实现 `NodeMobile.start` 分支并复测同一套契约；
5. 记录冷启动耗时、内存与包体积增量。

## 回滚

删除 `Packages/CatVodNode/` 与 CI 中的 `CatVodNode tests` 步骤即可，其它模块不依赖本包。
