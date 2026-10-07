# M01P5 js2p 宿主契约（bundle 静态分析）

- 状态：分析完成，**决策已定**（走真 Node 内嵌；停止 JSC shim 方案）
- 时间：2026-10-07
- 产物：`docs/js2p宿主契约.md`、`Tools/analyze_js2p.py`、`Tools/out/js2p-report.txt`（报告不入库）

## 目标

用数据回答两个问题：
1. 这个 `index.js`（6.29MB）能否在 JavaScriptCore + Node shim 上运行？
2. 宿主必须提供什么（端口、注入、回调、路由、环境变量）？

## 结论

1. **不能**。bundle `require` 了 `net`/`tls`/`dns`/`http2`/`worker_threads`/`fs`/`perf_hooks`/`async_hooks`/`diagnostics_channel`/`stream`/`zlib`/`crypto` 等 Node 内建，并打包了 **fastify 5** 生态（`forwarded`/`proxy-addr`/`toad-cache`/`fast-json-stringify`/`ajv`）+ `node-fetch` + `pako`。
   → 采用**路线 B：随包内嵌真 Node**（iOS：nodejs-mobile libnode；macOS：随包 node 可执行文件或 libnode）。
   → 明确排除路线 C（运行时下载 + dlopen）：未签名 IPA 侧载后无法加载事后下载的 dylib。
2. 宿主契约已实测固化（启动条件、端口、就绪日志、路由前缀、可选 `messageToDart` 回调），见 `docs/js2p宿主契约.md`。
3. 意外收获：自启动条件是 `process.argv[1]` 以 `index.js` 结尾且未注入 `catServerFactory`——**用真 Node 跑 `node index.js` 时服务会自启，不需要实现 serverFactory**，宿主只需分配端口、采集 stdout、调用 `/spider/<key>/*` 路由。

## 影响

| 受影响项 | 变化 |
| --- | --- |
| `CatVodSource` 架构 | 新增 `NodeRuntimeAdapter`（iOS 内嵌 libnode / macOS 子进程），`JsVirtualMachine` 不再需要 JSC shim 实现（保留协议以便未来替换） |
| 依赖 | 新增 nodejs-mobile（Node 18.20.4）随包依赖；已登记 `ThirdParty/mpvkit.lock.json` |
| 体积/性能预算 | 需在 M1.6 实测（libnode 体积、冷启动、内存、iOS 无 JIT 下的执行耗时） |
| CI | 需要能构建内嵌 libnode 的产物；CI 仍不签名 |
| M2 验收 | 以「真 Node 起服务 → `/config/sites/list` → `/search` → `/play`」全链路为准 |

## 回滚

分析产物与文档可保留；若 M1.6 PoC 证明 iOS 无法承载 libnode，则回退方案为：
1. **仅 macOS 支持 js2p 通道**（随包 node），iOS 侧只保留 JSON/XML 猫源通道；
2. 或改用远程 node 服务（自托管）承担 js2p，客户端只做 HTTP 调用（需用户自备服务器）。
