# M02P1 UI 版本自适应（各系统用各自原生 UI）

- 状态：已完成
- 时间：2026-10-07
- 需求：iOS/iPadOS 15.0 及以上，**各系统版本用各自的原生 UI 显示**（不跨版本仿制）

## 决策

| 能力 | iOS 15 | iOS/iPadOS 16+ | macOS 13+ | 备注 |
| --- | --- | --- | --- | --- |
| 导航容器 | `NavigationView` + `.stack` | `NavigationStack` | `NavigationStack` | iOS 15 无 `NavigationStack`，用其原生等价物 |
| 列表样式 | `.insetGrouped` | 同左 | `.inset` | `.insetGrouped` 在 macOS 不可用 |
| 工具栏 | `navigationBarItems` | `toolbar` + `.topBarLeading/.topBarTrailing` | `toolbar` + `.navigation/.primaryAction` | 让各版本用各自的原生工具栏语义 |
| 搜索 | `.searchable` + `.navigationBarDrawer(.always)` | `.searchable` | `.searchable` | 放置位置按版本取原生默认 |

**核心约束**：版本分支只允许出现在 `Packages/CatVodUI/Sources/CatVodUI/Platform/`，
业务视图不得写 `#available` / `#if os(...)`；`AnyView` 只允许出现在适配函数内。

## 产出

- `Packages/CatVodUI/Sources/CatVodUI/Platform/AdaptiveNavigation.swift`
  （`AdaptiveNavigationContainer`、`adaptiveListStyle()`、`adaptiveToolbar(leading:trailing:)`、`adaptiveSearchable(text:prompt:)`）
- `RootView` 改用上述基础件（去掉视图内的 `#if os(iOS)` 分支）
- `docs/UI 规范.md`（总原则、版本映射、禁止事项、验收方式）
- `docs/架构设计.md` 新增「UI 约定（版本自适应）」章节；`README.md` 规范章节补一条
- `PlatformShimsTests` 新增「版本自适应基础件可构造」用例（CI 上编译期验证各版本分支）

## 验收

- CI：`swift test --package-path Packages/CatVodUI` 通过 + iOS/macOS 双端未签名构建通过。
- 人工（需真机/模拟器）：iOS 15 与最新 iOS 各跑一遍导航/列表/工具栏/搜索；macOS 上确认窗口工具栏与列表为原生形态。

## 回滚

删除 `AdaptiveNavigation.swift`，把 `RootView` 恢复为按平台的 `NavigationView` 分支即可；
文档侧删除 `docs/UI 规范.md` 与两处引用。

## 后续（仍遵循同一原则）

`NavigationSplitView`（iPad/Mac 双栏）、`presentationDetents`（iOS 16+ 半屏弹层）、
`@Observable`（iOS 17+，低版本用 `ObservableObject`）、`.scrollContentBackground`（iOS 16+）、
`Grid`（iOS 16+）、macOS 的 `Settings` 场景。
