# M16P4 iOS 内嵌 libnode（nodejs-mobile / NodeMobile.xcframework）

- 状态：**代码与工程接线完成**（取产物脚本已实测通过、启动参数有单测、CI 会拉产物并编译 iOS）；
  **真机运行未验证** —— 需要在 Mac 上跑一次（见第五节）
- 依赖：M1.5（路线 B：必须内嵌真 Node）、M16P1（宿主适配）、M16P3（宿主会话与界面接线）
- 目标：让 iOS 也走「安卓同一套」—— 把 libnode 随包内嵌，由 `node_start` 启动，而不是只能靠 macOS 的外部 node 进程

## 一、为什么是 nodejs-mobile

M1.5 已判定：bundle `require` 了 `net`/`tls`/`dns`/`http2`/`worker_threads`/`fs`/`zlib`/`crypto` 等 Node 内建并打包了 fastify 5，
**不可能**用 JavaScriptCore + shim 承载（路线 A 已排除）；运行时下载 dylib 也被排除（未签名 IPA 加载不了）。
于是只剩「随包内嵌真 Node」，而移动端唯一成熟产物就是 **nodejs-mobile** —— 这也是安卓上游用的那一套。

## 二、产物（实测登记，写入 `ThirdParty/node-mobile.lock.json`）

| 项 | 值 |
| --- | --- |
| 版本 | `v18.20.4`（Node 18.20.4） |
| 文件 | `nodejs-mobile-v18.20.4-ios.zip` |
| 大小 / sha256 | 51,492,431 B / `8c5ca3a0d1e38de7f182a5642593e82593b820efd375a14b3ecafc4bcfee620e` |
| 解压布局 | `NodeMobile.xcframework`：`ios-arm64`（二进制 54,959,120 B）、`ios-arm64_x86_64-simulator`（115,463,536 B） |
| 模块 | `framework module NodeMobile`（自带 `Headers/NodeMobile.h` + `Modules/module.modulemap` → Swift 可直接 `import NodeMobile`） |
| C API | `int node_start(int argc, char *argv[]);` |
| 最低系统 / 许可 | iOS 13.0 / MIT（Copyright Node.js contributors；Modifications copyright (c) Janea Systems, Inc.） |

**产物不入库**：解压后 device + simulator 合计 ~170 MB。改为脚本按 sha256 取回（谁都能复现同一个产物）：

```bash
python Scripts/fetch_nodejs_mobile.py          # 下载（如需）+ 校验 + 解压到 ThirdParty/nodejs-mobile/
python Scripts/fetch_nodejs_mobile.py --check  # 只校验
```

## 三、实现

| 文件 | 内容 |
| --- | --- |
| `Scripts/fetch_nodejs_mobile.py` | 取产物：读 `ThirdParty/node-mobile.lock.json` → 下载 → **sha256 校验** → 只解 `NodeMobile.xcframework`（跳过 500 个头文件） |
| `ThirdParty/node-mobile.lock.json` | 版本 / URL / 字节数 / sha256 / 布局 / API / 许可，一处登记 |
| `CatVodNode/NodeMobileLaunchPlan.swift` | **纯计算**层：`argv` 与要 `setenv` 的键值 + C 指针封装（`withCArguments`）；平台无关，可单测 |
| `CatVodNode/NodeMobileRuntime.swift` | `#if canImport(NodeMobile)` 的运行时：后台线程（2 MB 栈）跑 `node_start`、fd 1/2 重定向到管道、按行解析就绪信号；与 macOS 的 `NodeRuntimeAdapter` **同一套规则** |
| `CatVodNode/NodeRuntimeEnvironment.swift` | 平台选择集中在一处：iOS 用 libnode（`canImport(NodeMobile)`），macOS 用进程；`isRuntimeAvailable` + 可读的不可用原因 |
| `CatVodSource/JS2PHostService.swift` | 改用 `NodeRuntimeEnvironment`；新增 `runtimeUnavailableReason` 供界面直接展示 |
| `project.yml` | iOS target 链接并嵌入 `ThirdParty/nodejs-mobile/NodeMobile.xcframework` |
| `.github/workflows/build.yml` | build/release 两个作业：先缓存并拉取产物，再 `xcodegen generate`（这样 CI 真的会**链接并编译** libnode） |

### 关键设计决策

1. **契约不变，只换承载方式**：`NodeMobileRuntime` 与 `NodeRuntimeAdapter` 实现同一个 `NodeRuntimeLaunching`，
   就绪解析、超时、早退、诊断输出全部复用 `NodeReadiness` 与同一套状态机 —— 上层 `JS2PHostService` 一行都不用改。
2. **不依赖 cordova 的 bridge**：插件是通过 JS 预载 + `_SYSTEM_` 通道把日志送到 host 的；
   我们只需要 bundle 打印的那**一行**就绪日志，直接 `dup2` 抓 fd 1/2 更少依赖，也与 macOS 的进程方式更接近。
3. **`stop()` 的语义如实标注**：`node_start` 一旦调用就不会返回，nodejs-mobile 也没有「停实例」API。
   因此 `stop()` 只**断开日志采集**，Node 与服务仍在跑；再次 `start()` 返回同一个 baseURL 而不重复启动
   （`node_start` 不可重入）。要真正重启只能重启 App —— 这条写在类型注释里，而不是假装停掉了。
4. **argv 与自启动条件对齐**：`["node", "<script>"]`，于是 `process.argv[1]` 以 `index.js` 结尾，
   正好满足 bundle 的自启动判定（否则它会静默不监听）。
5. **平台差异只出现在一个文件里**：业务代码不写 `#if canImport(NodeMobile)`，只有 `NodeRuntimeEnvironment` 需要。

## 四、明确未验证（需要 Mac 真机，不能靠这里猜）

| # | 待验证 | 为什么要先验证它 | 若不成立的应对 |
| --- | --- | --- | --- |
| 1 | `node_start` 之后 stdout **是否真的进管道** | nodejs-mobile 可能把日志硬编码到 os_log，而不是 fd 1 —— 就绪行抓不到就没法拿端口 | 改走 `-r <preload>`：预载脚本 patch `console.log`，把就绪行经 bridge 回传（`NodeMobileLaunchPlan` 已预留 `-r`） |
| 2 | `setenv` 注入的 `DEV_HTTP_PORT`/`HOST`/`NODE_ENV` 是否被 bundle 读到 | 端口与监听地址全靠它；读不到会落到默认 9988/0.0.0.0 | 若要改成 `argv` 传参，需确认 bundle 是否支持（契约里它只读 env） |
| 3 | 体积 / 冷启动 / 常驻内存 / 无 JIT 性能 | 决定 iOS 侧是否真的可用（M1.6 验收标准） | 关掉不必要的日志、复用实例、`--max-old-space-size` |
| 4 | 单实例、无 `child_process` 是否影响 bundle 关键路径 | bundle 若依赖 worker/child 会失败 | 查是否有环境变量可关（M01P6 风险表已列） |
| 5 | bundle 在 iOS 的**可写目录**里能否正常读写（当前落在 Caches 目录，iOS 不控制 cwd） | bundle 会写自己的缓存/配置；目录不可写会启动即失败 | 需要时把 bundle 与工作目录挪到 Application Support，并在启动前 `chdir` 过去 |

## 五、Mac 上的验证步骤

```bash
python3 Scripts/fetch_nodejs_mobile.py      # 取产物（sha256 校验）
python3 Scripts/fetch_nodejs_mobile.py --check
xcodegen generate                           # 工程已把 NodeMobile.xcframework 链进 iOS target
```

然后在 Xcode 里跑模拟器（或真机）：接口填 `https://9280.kstore.vip/ceshi/index.js` → 加载
→ 期望「接口管理 → Node 宿主」显示 `宿主运行中：http://127.0.0.1:<port>，站点 85 个…`。

反向用例（都要给出可读原因，不能静默）：

- 删掉 `ThirdParty/nodejs-mobile/` 再生成工程：应能**编译**，界面显示「当前构建没有内嵌 Node 运行时…」；
- macOS 上不装 node：显示「未找到 node 可执行文件…」；
- 宿主起来但未探活通过：显示「就绪行已出现，但 `GET /health` 未通过」并附宿主输出。

## 六、回退方式

- 只想跑 macOS：不取产物即可（`canImport(NodeMobile)` 为假 → 自动走进程分支）；
- 彻底回退 iOS：删掉 `project.yml` 里那两行 framework 依赖 + `Scripts/fetch_nodejs_mobile.py` 的 CI 调用，
  再把 `NodeRuntimeEnvironment` 的 iOS 分支改回「不可用」即可；其余代码（会话层/界面）不受影响。

