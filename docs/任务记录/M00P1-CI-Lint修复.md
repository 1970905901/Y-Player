# M00P1 CI Lint 链路修复（SwiftFormat / SwiftLint）

- 状态：待 CI 验证
- 时间：2026-10-07
- 现象：GitHub Actions 里 `Lint (SwiftLint / SwiftFormat)` 作业**显示 success**，但界面上挂着两个红色注解：
  - `Process completed with exit code 127`
  - `Process completed with exit code 70`

## 一、根因（来自 job 日志，非猜测）

| 退出码 | 步骤 | 日志原文 | 原因 |
| --- | --- | --- | --- |
| 127 | SwiftLint | `swiftlint: command not found` | **runner 镜像上没装 SwiftLint**（装了 SwiftFormat 0.63.0） |
| 70 | SwiftFormat | `error: Unknown option 'indent' in configuration file.` | `.swiftformat` 语法在新版本下**已失效** |

两条都因为步骤是 `continue-on-error: true`，所以作业结论仍是 success ——
也就是说：**它们此前什么也没检查，只是每次报两个红叉**。

### 70 的准确原因（查源码确认）

SwiftFormat 0.63.0 `Sources/Arguments.swift`：

```swift
if !key.hasPrefix("-") {
    throw FormatError.options("Unknown option '\(key)' in configuration file")
}
```

配置文件里的键**必须以 `-` 开头**（`--名称 值` 逐行），我们写的 `indent = 4` 是 `key = value` 老语法，
解析器把它当成一个不认识的键名，于是报 `Unknown option 'indent' …`（它是文件第一行，所以报的就是它）。

顺带核对（以 0.63.0 的 `Sources/OptionDescriptor.swift` 的 `argumentName` 为准，共 155 个）：选项名是
**kebab-case**，`max-width` / `swift-version` / `trim-whitespace` / `strip-unused-args` / `wrap-arguments` /
`empty-braces`；而 `numbers` 这类键在 0.63 里**不存在**。`indent` 键存在但类型是**缩进字符串**（默认 `"    "`），
不需要也不应设成数字。

## 二、修复

1. **装工具**：lint 作业新增 `brew install swiftformat swiftlint` 并打印版本（不再依赖镜像碰巧带了什么）。
2. **改语法**：`.swiftformat` 全部改写为 `--名称 值`，名称只用 0.63 的 `argumentName`：
   `--swift-version 6.0` / `--max-width 140` / `--linebreaks lf` / `--trim-whitespace always` /
   `--strip-unused-args closure-only` / `--wrap-arguments before-first` / `--wrap-parameters before-first` /
   `--semicolons inline` / `--empty-braces spaced`；`exclude` 移到命令行（`--exclude …`）。
3. **补 `|| true`**：两步保留 `continue-on-error: true`（lint 目前非阻断，M2 起收紧），
   同时让命令自身以 0 退出 —— findings 仍完整打进日志，但不再产生红色注解。**能看见，但不挡路**。

## 三、验收

- lint 作业日志里应出现 `swiftformat --version` / `swiftlint version` 的真实版本号；
- 不再出现 `command not found` 与 `Unknown option`;
- 两个步骤的注解消失（作业仍为 success）；
- 若 SwiftLint/SwiftFormat 报出**真实**问题，日志里能看到（先记录，M2 起再逐个收紧为阻断）。

## 四、清掉存量 violation（SwiftLint 共 24 条：5 error + 19 warning）

工具真正跑起来后，第一次就暴露了 24 条问题。全部处理如下（**这些都是真问题，不是噪音**）：

| 规则（级别） | 位置 | 处理 |
| --- | --- | --- |
| `identifier_name`（**error**） | `Site.HomePageAliasKeys` 的 `home_page` / `web_home` | 元素名改成 Swift 风格，**raw value 保持上游 JSON 键** |
| `empty_count`（**error** ×3） | `DetailCacheTests` 的 `stats.count == 0` | `Statistics` 增加 `isEmpty`，测试改用 `stats.isEmpty` |
| `modifier_order`（w ×11） | `SystemPlayerEngine` / `URLSessionTransport` / `DetailCache` / `NodeRuntimeAdapter` | `public nonisolated` → `nonisolated public` |
| `redundant_sendable`（w） | `@MainActor struct PlayerCoordinator: Sendable` | 去掉 `: Sendable`（全局 Actor 隔离类型隐式 Sendable） |
| `redundant_type_annotation`（w） | `SpiderResult.url` | 去掉冗余类型标注 |
| `legacy_swiftui_aspect_ratio`（w ×2） | `HomeView+Data` / `VodDetailView` | `aspectRatio(contentMode: .fill)` → `scaledToFill()` |
| `large_tuple`（w） | `PictureFillerTests` 的 3 元组辅助函数 | 改二元组 + 自动生成名称 |
| `trailing_newline`（w） | `PlatformShimsTests` | 去掉多余尾空行 |
| `nesting`（w ×2） | `PlaybackURLs.Entry.CodingKeys` / `ShortNameKeys` | 配置 `nesting.type_level: 2`（两套键空间是有意为之，见注释） |

## 五、仍未收敛的一项（**已由 M00P2 收敛，见下**）

> **更新（同日）**：本项已在 `M00P2 全量格式化` 中完成 ——
> `--ifdef no-indent` 处理 `#if` 风格分歧，其余规则逐条决策（采纳/禁用，理由写在 `.swiftformat` 注释与 M00P2 文档里），
> 结果 **`0/97 files require formatting`**，并把 lint 两个步骤**升级为阻断**（不再 `|| true`）。
> 下面保留当时的记录，便于回溯判断过程。

SwiftFormat 用**默认全量规则集**检查时报 `67/93 files require formatting`。原因有两类：

1. **风格分歧（已处理）**：`#if os(...)` / `#available` 块内我们不额外缩进，
   而 SwiftFormat 默认 `--ifdef indent`；已在 `.swiftformat` 显式设为 `--ifdef no-indent` 并写明理由。
2. **尚未采纳的规则（待定）**：如 `redundantReturn`（我们保留显式 `return`）、
   `hoistPatternLet`、`wrapIfStatementBodies`、`opaqueGenericParameters` 等。
   要消灭这批报告，需要对全仓库跑一次 `swiftformat` 并**逐文件 review**（会产生 60+ 文件的大 diff）。

**当前策略**：`--lint` 保持信息性（非阻断），日志里能看见；等 M2 收尾或 M3 开始前，
单独开一个「全量格式化 + review」任务把它收敛成 0，再把该步骤升级为阻断。
在此之前，任何人请不要把「lint 步骤是 success」当成「格式没问题」。


## 四、教训（写给未来的自己）

- **"非阻断"不等于"没在检查"**：`continue-on-error` 会让失败静默，必须同时确认工具真的存在、配置真的被解析。
- **配置语法会变**：SwiftFormat 配置文件已从 `key = value` 变为 `--key value`；升级工具时要一起看配置解析代码。
- **版本以实测为准**：本仓库的 CI 镜像自带 SwiftFormat 0.63.0，因此所有选项名都以该版本的 `OptionDescriptor.swift` 为准，
  不凭记忆写。
