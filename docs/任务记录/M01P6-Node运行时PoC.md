# M01P6 Node 运行时 PoC（js2p 主接口落地）

- 状态：待执行（需 macOS/真机）
- 依赖结论：`docs/js2p宿主契约.md`（M1.5 已判定必须随包内嵌真 Node）
- 目标：在 iOS 与 macOS 上跑通「内嵌 Node 执行 bundle → 起本地服务 → 调 `/spider` 路由」

## 一、范围

1. **iOS**：集成 nodejs-mobile **v18.20.4**（iPhone arm64 + 模拟器 arm64/x86_64），随包内嵌（framework 或静态库）。
2. **macOS**：随包 `node` 可执行文件 + `Process` 启动（或自编译 libnode），验证 Gatekeeper 处理方式。
3. **统一适配层**：`NodeRuntimeAdapter` 负责分配端口、注入环境变量、采集 stdout/stderr、解析就绪行、暴露 baseURL。
4. **端到端**：`index.js`（6.29MB）下载 → MD5 校验 → 执行 → `/init /home /category /detail /search /play` 全链路（复用 `CatSpiderHTTPClient`）。

## 二、验收标准（可量化）

| 项 | 目标 |
| --- | --- |
| 就绪解析 | 能从 stdout 稳定解析 `CatVodSpiderios listening on http://127.0.0.1:<port>`，并得到真实端口 |
| 端口冲突 | 注入的端口被占用时，bundle 自增重试后仍能拿到正确端口 |
| 冷启动 | 首次（含 6.29MB 下载 + 执行 + 监听）记录耗时；二次启动（命中 MD5 缓存）记录耗时 |
| 内存 | 记录常驻内存增量（用于判断 iOS 可用性） |
| 体积 | 记录 ipa/app 的体积增量（libnode 预期数十 MB） |
| 站点清单 | 确定 `/config/sites/list`、`/sites/list`、`/spider/list`、`/config` 中哪个可用，并解析出 `sites[].api` 形态 |
| 路由可用 | `/init`、`/home`、`/category`、`/detail`、`/search`、`/play` 均能返回符合 `SpiderResult` 的 JSON |
| Node 内建可用性 | 逐项确认 `net`/`tls`/`dns`/`http2`/`worker_threads`/`fs`/`zlib` 在 iOS 沙盒内可用；不可用项需确认是否在关键路径 |
| 稳定性 | 连续 20 次搜索/详情请求无崩溃、无内存持续增长 |

## 三、风险与备选

| 风险 | 备选 |
| --- | --- |
| iOS 无法承载 libnode（体积或权限） | 仅 macOS 支持 js2p 通道，iOS 只保留 JSON/XML 猫源通道 |
| `worker_threads` 在 iOS 不可用且属关键路径 | 寻找 bundle 是否可通过环境变量关闭该路径；否则评估在 Node 侧打补丁（需自建 libnode） |
| 无 JIT 导致执行过慢 | 调整 Node 启动参数（`--max-old-space-size`、关闭无需的优化）；评估 QuickJS 不可行（依赖 Node 内建） |
| 冷启动过慢 | 常驻 Node 进程（应用生命周期内复用）+ 预热 + 缓存 bundle |

## 四、产出

1. `Packages/CatVodSource/Sources/CatVodSource/Runtime/NodeRuntimeAdapter.swift`
2. `docs/任务记录/M01P6-Node运行时PoC.md` 的实测数据表（体积/耗时/内存）
3. `ThirdParty/` 中登记 libnode 版本、校验值与许可证
4. 若涉及自建 libnode：`Scripts/build-libnode.sh` 与版本锁定记录
