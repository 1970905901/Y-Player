# M16P4 iOS 内嵌 libnode（nodejs-mobile / NodeMobile.xcframework）

- 状态：**代码与工程接线完成，并在 iOS 模拟器上跑出了第一手数据**（见第七节）；
  **真机运行仍未验证** —— 需要你的设备（Windows 上侧载未签名 IPA 即可，见 `M03P2-实机验证清单.md`）
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
| `CatVodNode/NodePreloadScript.swift` | **预载脚本**（`-r` 注入）：把运行环境与致命错误**落盘**，并拦截 `process.exit`/`uncaughtException`/`unhandledRejection`。内嵌 node 是进程内嵌，崩了会把宿主一起带走 —— 没有它连证据都不剩（第七节） |
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

> **2026-10-07 补充**：上表第 1、2、5 项现在由**确定性探针**在 iOS 模拟器上直接判定
> （`Tests/YPlayer-iOSTests/EmbeddedNodeHostTests.swift`：自写最小 bundle，复刻就绪行/`/health`/`/full-config`/相对 `api`，
> **不依赖外网**）；第 4 项由预载脚本逐模块登记（日志里的 `preload module ok/MISSING: child_process|worker_threads`）。

## 五、Mac 上的验证步骤

```bash
python3 Scripts/fetch_nodejs_mobile.py      # 取产物（sha256 校验）
python3 Scripts/fetch_nodejs_mobile.py --check
xcodegen generate                           # 工程已把 NodeMobile.xcframework 链进 iOS target
```

然后在 Xcode 里跑模拟器（或真机）：接口填 `https://9280.kstore.vip/ceshi/index.js` → 加载
→ 期望「接口管理 → Node 宿主」显示 `宿主运行中：http://127.0.0.1:<port>，站点 85 个…`。

反向用例（都要给出可读原因，不能静默）：

- 删掉 `ThirdParty/nodejs-mobile/`：**xcodegen 会因为找不到该 framework 路径而报错**，这是刻意的
  （工程声明了依赖就不该悄悄降级）；要临时去掉 libnode，请同时移除 `project.yml` 里那两行依赖，
  此时 `canImport(NodeMobile)` 为假，界面显示「当前构建没有内嵌 Node 运行时…」；
- macOS 上不装 node：显示「未找到 node 可执行文件…」；
- 宿主起来但未探活通过：显示「就绪行已出现，但 `GET /health` 未通过」并附宿主输出。

## 六、回退方式

- 只想跑 macOS：不取产物即可（`canImport(NodeMobile)` 为假 → 自动走进程分支）；
- 彻底回退 iOS：删掉 `project.yml` 里那两行 framework 依赖 + `Scripts/fetch_nodejs_mobile.py` 的 CI 调用，
  再把 `NodeRuntimeEnvironment` 的 iOS 分支改回「不可用」即可；其余代码（会话层/界面）不受影响。

## 七、模拟器实测（CI，2026-10-07）与由此产生的改动

第一次在 iOS 模拟器上真跑（`simulator` 作业）得到两条结论，一好一坏。

**好：App 与内嵌运行时在真 iOS 运行时上都没问题。** `SimulatorSmokeTests` 三条全过 ——
能执行到测试体本身就说明 MPVKit 与 `NodeMobile.framework` 的动态库**都加载成功**（没有 `dyld` 缺库），
并且 iOS 上 `JS2PHostService.isRuntimeAvailable == true`、未实装的内核如实报不可用。

**坏：真 bundle 那条用例把测试进程一起带走了。** 时间线（取自作业日志）：

| 时刻 | 现象 |
| --- | --- |
| 12:41:33.217 | `Test Case 'testHostStartsAndReturnsSites' started.` |
| 12:41:33.814 / 34.436 | App 进程发出两次网络连接（6.29 MB bundle 下载开始） |
| — | 此后**没有任何** `passed` / `failed` 行 |
| 12:41:46.720 | `Restarting after unexpected exit, crash, or test timeout`（距开始 13.5 秒） |

13.5 秒不是超时（XCTest 默认 600 秒），也没有任何断言输出 —— 这是**进程级消失**：
内嵌 node 一旦遇到致命错误或 `process.exit()`，由于它是**进程内嵌**，宿主 App 会跟着一起死，
而 `dup2` 抓到的 stdout 缓冲也随进程蒸发，事后无从取证。

**所以这一轮的改动是三件事，而不是「把那条用例关掉」：**

1. `NodePreloadScript`（新增）经 `-r` 注入：把 node 版本、`argv`、`cwd`、`DEV_HTTP_PORT`/`HOST`、
   **各核心模块可用性**与所有致命错误**逐行追加到落盘日志**，并拦截
   `process.exit` / `uncaughtException` / `unhandledRejection` —— 崩溃从「闪退」变成
   「界面上的宿主未就绪 + 可回读的日志尾部」（`JS2PHostService.hostLogPath()`，报错信息里自动附尾部）；
2. 探针分两层：`EmbeddedNodeHostTests`（自写最小 bundle、**不依赖外网**，判定第 1/2/5 项）作为主线红灯依据；
   `RealBundleHostProbeTests`（真 bundle，需 `YPLAYER_NODE_PROBE=real-bundle`）在 CI 里 `continue-on-error`，只作信息；
3. 每一步 `print` 后立刻 `fflush`：下次若再出现进程消失，日志里能直接看出死在**哪一步**。

### 2026-10-07 首轮模拟器结果（真 iOS 运行时）

| 观察到的事实 | 结论 |
| --- | --- |
| `EmbeddedNodeHostTests` **passed**（0.346 s；从 `host starting` 到断言完成 **1.7 s**） | **第 1 项成立**：`dup2` 抓到的 stdout 里确实有就绪行 —— 能拿到 baseURL 才可能取到站点；第 2 项（env 注入）、第 5 项（容器临时目录里的脚本 node 读得到）同时成立 |
| 预载默认开启（`prefersPreload: true`）而链路仍然通过 | libnode 接受 `-r`，预载不会破坏启动 |
| `RealBundleHostProbeTests` **skipped** | 首次把 `YPLAYER_NODE_PROBE` 放在 shell `env:` 里 —— App 进程的环境来自**模拟器启动**，必须用 `TEST_RUNNER_` 前缀。已修（`simulator.yml`），真 bundle 待下一轮 |
| `testMpvDependencyLinkedButEngineNotImplemented` 耗时 **13.6 s** | 第二轮已结案：`MpvAvailability` 与 `PlayerEngineKind` 全是**编译期常量**，源码里**没有任何 `import Libmpv`**（只有 `canImport` 判断），界面调用 `summary` 只是一次字符串插值 —— 不可能花 13.6 s。第二轮同一批 3 个用例合计 **0.003 s**，故它属测试运行器的一次性开销，与我们的代码路径无关 |

### 2026-10-07 第二轮模拟器结果（真 bundle 首次绿灯）

`simulator` 运行 `37629251023`（提交 `368cd53`），`TEST_RUNNER_YPLAYER_NODE_PROBE` 修复后首次真正跑到真 bundle：

| 观察到的事实 | 结论 |
| --- | --- |
| `EmbeddedNodeHostTests` **passed**，1 个用例 0.447 s | 确定性主线继续成立（自写最小 bundle，不依赖外网） |
| `SimulatorSmokeTests` **passed**，3 个用例 **0.003 s** | 上表 13.6 s 异常消失，结案 |
| `RealBundleHostProbeTests` **passed**，1 个用例 **9.278 s**、0 失败 | **首次在真 iOS 运行时跑通真 bundle**：下载 6,291,879 字节 → libnode 起来 → 就绪行解析 → `/full-config` 站点断言全过。此前那次「下载完成后 13.5 秒进程消失」在预载修复后**复现不出来** |
| 探针日志里最后一条是 `host starting` | **新发现的诊断缺口**：fd 1/2 全被 `dup2`，之后的步骤只进「宿主输出」、不进 CI 日志。已把 `NodeProbeSupport.step` 改成 **`print` + `NSLog` 双通道**（`NSLog` 走统一日志，重定向影响不到），下一轮生效 |

真 bundle 探针**继续**留在 `continue-on-error`：它依赖外网与上游 bundle 是否正常，
属于「环境 + 上游」变量，不该当主线红灯依据；主线仍由 `EmbeddedNodeHostTests` 判定。

第 3 项（体积 / 冷启动 / 常驻内存 / 无 JIT 性能）与第 4 项（`child_process` / `worker_threads`）
仍待真 bundle 探针给出：预载会把 `preload module ok/MISSING: …` 写进落盘日志，
下次跑真 bundle 时直接读那段即可。

预载依赖 libnode 的选项解析接受 `-r`（首轮已间接验证）。若某个版本不接受
（症状同样是启动即消失），可用 `NodeRuntimeConfiguration(prefersPreload: false)` 关掉它 ——
开关与理由都写在类型注释里。

