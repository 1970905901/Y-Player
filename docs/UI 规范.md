# UI 规范（版本自适应：各系统用各自原生 UI）

## 一、总原则

1. **原生优先，不做跨版本仿制**：每个 iOS/iPadOS 版本都用**它自己那套原生 UI**呈现。
   - 不给 iOS 16+ 强行套 iOS 15 的样式，也不为「统一观感」而自绘系统控件。
   - 视觉与交互（导航栏、列表分组、工具栏、搜索栏、弹窗、上下文菜单、手势）全部交给系统。
2. **版本分支只允许出现在基础件里**：业务视图**不得**写 `#available` / `#if os(...)`；
   差异统一收敛到 `Packages/CatVodUI/Sources/CatVodUI/Platform/`。
3. **iOS 15 是下限**：凡 iOS 15 缺失的 API，必须提供该版本的**原生等价实现**（而不是自绘替代）。
4. **macOS 用 macOS 的外观**：不使用 iOS 专属样式（如 `.stack` 导航样式、`ToolbarItemPlacement.topBarLeading`）。

## 二、版本/平台映射（基础件已实现）

| 能力 | iOS 15 | iOS/iPadOS 16+ | macOS 13+ | 基础件 |
| --- | --- | --- | --- | --- |
| 导航容器 | `NavigationView` + `.stack` | `NavigationStack` | `NavigationStack` | `AdaptiveNavigationContainer` |
| 列表样式 | `.insetGrouped`（iOS 原生分组） | 同左 | `.inset`（macOS 原生） | `adaptiveListStyle()` |
| 工具栏 | `navigationBarItems` | `toolbar { ToolbarItem(.topBar…) }` | `toolbar { .navigation / .primaryAction }` | `adaptiveToolbar(leading:trailing:)` |
| 搜索栏 | `.searchable` + `.navigationBarDrawer(displayMode:.always)` | `.searchable`（新放置语义） | `.searchable` | `adaptiveSearchable(text:prompt:)` |

后续会按需补充（仍遵循同一原则）：`NavigationSplitView`（iPad/Mac 双栏，iOS 16+/macOS 13+）、
`presentationDetents`（iOS 16+ 半屏弹层）、`@Observable`（iOS 17+；iOS 15/16 用 `ObservableObject`）、
`.scrollContentBackground`（iOS 16+）、`Grid`/`.gridCellColumns`（iOS 16+）、
系统设置页风格（iOS 的 `Form` + 分组；macOS 的 `Settings` 场景）。

> 已落地：**设置页**（M02P11）用 `List` + `adaptiveListStyle()`（iOS 的 `insetGrouped` / macOS 的 `inset`）
> 呈现系统设置那种分组形态，**不用 `Form`**：`Form` 在 macOS 上会退化成另一套观感，
> 与本规范「各系统用各自原生外观」的目标重复。

## 三、禁止事项

- ❌ 用 `UIDevice` 型号判断代替系统外观判断。
- ❌ 自绘导航栏/返回按钮/搜索框以「统一观感」。
- ❌ 在业务视图里散落 `#if os(iOS)` / `#available`。
- ❌ 使用 macOS 不可用的 iOS 专属 API（如 `.navigationViewStyle(.stack)`、`.listStyle(.insetGrouped)`）。
- ⚠️ `AnyView` 仅允许出现在需要按版本返回不同具体类型的适配函数里（如 `adaptiveSearchable`），业务视图不得使用。

> 例外说明：`#if canImport(...)` 用于「可选原生依赖」的能力探测（例如 `CatVodPlayer` 里的
> `#if canImport(Libmpv)` / `#if canImport(Libavformat)`），与本节的 UI 版本分支不是一回事，
> 它必须留在拥有该依赖的包内，并且**只能用于能力判定**（如 `PlayerEngineKind.isAvailable`），
> 不得用来切换 UI 呈现。

## 四、验收方式

- iOS 15 与最新 iOS 模拟器上各跑一遍：导航推进/返回、列表分组、工具栏按钮、搜索框位置与行为必须与系统习惯一致。
- macOS 13+ 上验证：窗口工具栏、列表风格、菜单与快捷键为 macOS 原生形态。
- 代码审查：`Packages/CatVodUI/Sources/CatVodUI/Platform/` 之外不应出现版本分支。
