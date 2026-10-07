# YPlayer

基于 [FongMi/TV](https://github.com/FongMi/TV) / [CatVod](https://github.com/FongMi/CatVodSpider) 生态的 **Apple 平台影音壳**，Swift 实现，iOS/iPadOS 15+ 与 macOS 13+。

参考实现：[Silent1566/webhtv](https://github.com/Silent1566/webhtv)（作为协议与交互的兼容基准，不移植其 Java/Android 实现）。

## 核心能力（规划）

| 能力 | 说明 |
| --- | --- |
| 源协议 | `type 0/1/2/4`（XML/JSON CMS、HTTP+base64 ext）完整；`type 3` 支持 CatSpider HTTP 与 JS Spider |
| **js2p 主接口** | 支持 `index.js` + `index.js.md5` 形态的 JS 源：下载 → MD5 增量校验 → 在 JS 运行时执行 → 本机 HTTP 服务 → 按 CatSpider 路由调用 |
| 播放内核 | 自研 `PlayerEngine` 抽象：`MpvEngine`（libmpv，MPVKit LGPL）+ `FFmpegEngine`（VideoToolbox/Metal/AudioToolbox/libass 自研） |
| 网络 | `headers`/`hosts`/`doh`/`proxy`/`ads`/`hlsRules`/`rules` 嗅探规则与本地代理服务 |
| 不支持的形态 | `csp_*.jar`（需 JVM）、`.py`（需 CPython）、Widevine/PlayReady；UI 会明确给出原因 |

## 目录结构

```
Apps/                 iOS / macOS 应用入口（仅入口、Resources、Assets）
Packages/             SwiftPM 本地包
  CatVodCore/         协议模型、宽松解码、播放列表/URL 规则（仅 Foundation，可跨平台单测）
  CatVodNet/          HTTP 传输抽象、请求管线、本地 HTTP 服务
  CatVodSource/       站点客户端、CatSpider 协议、js2p 宿主与 JS 运行时、解析与嗅探
  CatVodPlayer/       播放内核抽象 + MpvEngine + FFmpegEngine
  CatVodStore/        持久化（站点/收藏/历史/进度）
  CatVodUI/           跨端 SwiftUI 组件与平台 shim
docs/                 架构、协议兼容矩阵、播放器设计、任务记录
Tools/                js2p bundle 分析脚本（产出不入库）
ThirdParty/           原生依赖锁定与许可证清单
```

## 环境要求

- **Xcode 16.4**（本仓库与 CI 使用同一版本）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- SwiftLint / SwiftFormat（CI 镜像已预装）
- 目标平台：iOS/iPadOS 15.0、macOS 13.0

## 构建

```bash
# 1. 生成 Xcode 工程
xcodegen generate

# 2. 单测（各包独立，最快的反馈回路）
swift test --package-path Packages/CatVodCore
swift test --package-path Packages/CatVodNet
swift test --package-path Packages/CatVodSource

# 3. iOS 未签名构建
xcodebuild build -project YPlayer.xcodeproj -scheme YPlayer-iOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# 4. macOS 构建
xcodebuild build -project YPlayer.xcodeproj -scheme YPlayer-macOS \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

## 发布（未签名，非 App Store）

打 tag 后由 GitHub Actions 产出：

- `YPlayer-unsigned.ipa`（iOS/iPadOS，需自行侧载并重签）
- `YPlayer-macOS-unsigned.zip`（macOS 13+）

## 工程规范

- **单类型单文件**；公开 API 必须写 DocC 注释，并标注对应的上游字段/文件
- 禁止强解包（`force_unwrapping`）；错误统一走 `CatVodError`
- 并发：网络与存储用 `actor`，UI 层 `@MainActor`；`CatVodCore`/`CatVodNet`/`CatVodSource`/`CatVodStore` 使用 Swift 6 语言模式，`CatVodPlayer`/`CatVodUI` 先保持 Swift 5 模式（C API 交互密集，后续迁移）
- 每个任务一份 `docs/任务记录/Mxx-*.md`，记录调研、决策、验收与回滚
- 提交信息使用 Conventional Commits

## 协议兼容性

逐字段的支持状态见 [`docs/协议兼容矩阵.md`](docs/协议兼容矩阵.md)。
js2p（JS 源）宿主契约见 [`docs/js2p宿主契约.md`](docs/js2p宿主契约.md)。

## 工具（Tools/）

仓库自带几个与 CI / js2p 分析相关的小工具（均为 Python 3，Windows 与 macOS 通用）：

| 脚本 | 用途 |
| --- | --- |
| `analyze_js2p.py` | 下载 js2p bundle、校验 `index.js.md5`、抽取 `require` 清单与宿主契约上下文，产出 `Tools/out/js2p-report.txt` |
| `github_bootstrap.py` | 创建 GitHub 仓库（幂等，已存在则跳过）、推送本地提交、把 `origin` 重置为不含 token 的干净地址 |
| `gh_probe.py` | 查询仓库工作流状态、最近运行、指定提交的 check-runs |
| `gh_actions_report.py` | 列出运行与作业步骤，抓取失败作业日志并抽取关键错误行 |

用法示例：

```bash
python Tools/analyze_js2p.py
python Tools/gh_probe.py <token> <owner>/<repo> [sha]
python Tools/gh_actions_report.py <token> <owner>/<repo> [run-id]
```

> 安全约定：token 仅作为命令行参数传入，**不写入任何文件、不提交、不进 remote 配置**；脚本会把日志中的 token 替换为 `***`。
> 日志与缓存目录 `Tools/out/`、`Tools/.cache/` 已在 `.gitignore` 中。

## 许可与免责声明

- 本项目以 **GPL-3.0** 发布（跟随上游生态），第三方依赖许可见 `ThirdParty/LICENSES`。
- 本软件**不内置、不提供、不分发任何影视内容、接口源或直播源**；所有接口由使用者自行添加。
- 本项目仅供技术学习与研究使用，使用者需自行承担使用产生的一切后果，并遵守所在地法律法规。
