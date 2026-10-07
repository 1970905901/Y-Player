# M03P1 MPVKit 落地方案（依赖接入 → 渲染 PoC → 引擎实现）

- 状态：**方案已定，第 1 步（lock 文件对齐）已完成**；第 2 步（接依赖）待执行；第 3 步需要 Mac/真机
- 依赖：M2（`PlayerEngine` 抽象与 `PlayerCoordinator` 严格选择）、`docs/任务记录/M02P3-播放设置手动选择.md`
- 目标：把 M3 的 MPV 内核真正接进来，同时**每一步都让 CI 保持可绿**

## 一、已核实的事实（来自 MPVKit 1.0.0 的 SwiftPM manifest，非推测）

| 项 | 值 |
| --- | --- |
| 仓库 / tag | `https://github.com/mpvkit/MPVKit.git`，`1.0.0` |
| tools / 平台 | `swift-tools-version:5.9`；iOS 15+ / macOS 12+ / tvOS 15+ / visionOS 1+（与本项目 iOS 15 / macOS 13 下限兼容） |
| 产物 | `MPVKit`（LGPL，target `_MPVKit`）与 `MPVKit-GPL`；本项目只用前者 |
| `_MPVKit` 依赖 | `Libmpv` + `_FFmpeg` + `Libuchardet` + `Libbluray` + `Libluajit`（仅 macOS） |
| `_FFmpeg` 依赖 | Libav* 七件套 + Libass/Libfreetype/Libharfbuzz/Libfribidi/Libunibreak + **MoltenVK**/Libshaderc_combined/lcms2/**Libplacebo**/Libdovi + Libssl/Libcrypto/gnutls 系 + Libdav1d/Libuavs3d |
| binaryTarget 数 | 共 38 个，其中 **LGPL 变体用到 29 个**（已按依赖图核对，写进 `ThirdParty/mpvkit.lock.json`） |
| 校验和来源 | 上游 manifest 即唯一事实来源；`Tools/sync_mpvkit_lock.py` 负责同步（含 `Libsmbclient` 这类**只被 GPL 变体使用**的目标不会被误算） |
| 许可 | LGPL-3.0（bundles）；合规提示写在 lock 文件的 `licenseCompliance` 里 |
| ⚠️ 已知风险 | 官方 README 明说 **Metal 后端只有补丁级支持、未官方支持** → 渲染路径必须实测 |

## 二、四步落地

### 第 1 步（已完成）：lock 文件与上游 manifest 对齐
- 新增 `Tools/sync_mpvkit_lock.py`：从 manfiest 解析全部 binaryTarget，按依赖图筛出 LGPL 变体用到的目标，写回 lock 文件并清空 `unverifiedChecksums`；
- 结果：29 条校验和 + `binaryTargetChecksumsSource`；升级 MPVKit 时必须重跑该脚本（lock 文件的存在意义就是「升级必须留痕」）。

### 第 2 步（下一步，CI 可完全验证）：只接依赖，不写引擎代码
- `Packages/CatVodPlayer/Package.swift` 加入 `.package(url: "https://github.com/mpvkit/MPVKit.git", exactVersion: "1.0.0")` 与 target 依赖 `"MPVKit"`，并提交 `Package.resolved`；
- CI 会证明：SwiftPM 能解析、29 个 xcframework 能下载校验、双端能链接、App 能构建；
- 代价：SwiftPM 缓存键变化 → 首次会冷下载（体积大，之后命中缓存）；这是它唯一的成本。

### 第 3 步（必须 Mac/真机）：渲染路径 PoC，三选一
MPVKit 的 Metal 后端是补丁级的，所以要用最小实验挑一条稳定路径：

| 候选 | 说明 | 风险 |
| --- | --- | --- |
| A. SW → Metal（`sw` 渲染 + 自绘 `CAMetalLayer`） | 最稳，CPU 拷贝多 | 4K 高帧率可能吃力 |
| B. MoltenVK（`gpu` 渲染 + `--vo=gpu`） | 性能最好，MPVKit 已带 MoltenVK/Libplacebo | 补丁级支持，行为可能不稳 |
| C. OpenGL ES（`gpu` + GL 后端） | 传统路径 | iOS 上已废弃，长期不可取 |

PoC 产出：同一段流的三条路径截图/帧耗时对照 + 结论（写进任务记录）→ 定下 `MpvEngine` 的默认渲染方式。

### 第 4 步：`MpvEngine` 真实实现
- 实现既有的 `PlayerEngine`（`load/play/pause/seek/currentState/teardown`）＋ `MediaResource`（headers/format/artwork）；
- **保持** `PlayerCoordinator` 的严格语义：手动选内核、不可用时如实报错、**不自动降级**；
- M4 的自研 `FFmpegEngine` 直接复用同一套 Libav*（不引第二份 FFmpeg）。

## 三、CI 能验到哪一步（提前说清，避免误会）

| 事项 | 本仓库 CI 能否验证 |
| --- | --- |
| 依赖解析 / 校验和 / 链接 / 双端编译 / 体积 | ✅ 能 |
| 引擎协议实现是否完整、状态机是否正确 | ✅ 能（单测，用假内核） |
| **画面是否真的出得来、性能如何** | ❌ 不能 —— 必须 Mac/真机（同 iOS libnode 那 5 项的性质） |
