# M11 Emby 视图 — 进度与续做说明

> 这里的每一条都是**当时读过代码后写下的**，带文件与行号锚点。
> 本地盲写、静态自检（无 Swift 编译器），所以每片都单独提交、单独绿。

## 已完成

| 片 | 内容 | 提交 |
| --- | --- | --- |
| 1 | 详情页顶部接元信息（TMDB：背景图 / 标题 / 简介，三态明说） | `478f179` |
| 2 | 海报方式（固定 / 随机 / 轮播）交给用户 + 顶部真正接过去 | `67a331c` |
| 3 | 大播放按钮（继续播放 + 站点集名 + 上次进度） | `90739bc` |
| 4 | 「⋯」菜单 + 元信息刮削开关 | `edf7cb5` |
| 7 | 骨架加载态（Emby 头部那处） | `b2ed236` |

新增文件：`Packages/CatVodUI/Sources/CatVodUI/TMDBDetailHeader.swift`
（自己拉元信息，不把加载状态塞进 `VodDetailView`）。

## 待做（按建议顺序）

1. **选集卡片接同一套取图 + 当前集居中**
   - 位置：`VodDetailView.swift` 的 `embyEpisodeSection`（约 424 行之后）。
   - 卡片图现在来自站点；接 `TMDBPosterSet` 时**不改 `PosterPicker` 那套逻辑**，
     顶部（`TMDBDetailHeader`）与卡片共用是当初的设计。
   - 当前集居中：参考视频里选中集在横滑中间。
2. **剧集列表抽屉**（排序 / 倒序）。
3. **顶部与封面重复的取舍**：`embyHeader`（359–412）的大封面用 `vod.vodPic`，
   而顶部已有 TMDB 大图 —— 参考视频里顶部只有一张。合并还是删这块封面，和片 1 一起看。
4. **全幅改造**：顶部现在是 `List` 里的一行（`VodDetailView.swift` 约 337 行）。
   做全幅要把这块挪到 `List` 外面 → **整块布局要动**，单独一步，不与上面几片混。
5. **手动匹配元信息**（「⋯」菜单第三项）。
6. **🔍 聚合搜索海报墙 / ♡ 收藏落地**：这两项各自的落地点是独立的片。
   **在那之前不放空按钮**（按下去没反应比没有按钮更糟）。
7. **经典布局的 `Text("加载中…")`**：文件里有两处加载分支，M11 只换了 Emby 那处；
   经典布局那处是否也换骨架，需要时再说。

## 选集卡片接图 — 先要定的事（已读代码，别临场决定）

`PosterPicker` 的接口是读准了的，够用：

- `index(step:seed:)` / `image(step:seed:)`，`step` 由调用方驱动；
- 卡片要「**每张各一张、同一张每次进来都一样**」→ 用 `step: index`（第 i 张卡片取第 i 张图）；
- `.random` 模式下只看 `seed`，所有卡片会取到**同一张** → 调用方传 `seed &+ UInt64(index)`
  打散即可。**不要为了卡片去改 `PosterPicker`** —— 「一组图 + 一种模式 → 出一张」这层
  是对的，卡片的差异是调用方的事。

**真正的槛不在取图，在数据放哪：**

`TMDBPosterSet` 现在是 `TMDBDetailHeader` 的**私有 `@State`**，而卡片在
`VodDetailView` 的 `embyEpisodeSection` 里 —— 两个视图互相看不见。

所以要先定（**跨文件的设计决定，定了再写**，别在视图里临时糊一个）：

1. 元信息提到共用层：`AppModel` 上加按片名缓存的元信息（要考虑键、失效、并发去重）；
2. 或者把「拉元信息」提到 `VodDetailView`，`TMDBDetailHeader` 改成只负责画（传值进来）。

倾向 1：搜索页/聚合海报墙以后也要同一份元信息，放 model 上才不用各拉一次。

顺带：卡片现在是**纯文字**（宽 92，高约 48），加图后卡片尺寸与那处骨架高度要一起改。


## 已定：元信息放 model（方案 1）

对着两条路比过之后**定了走 1**，理由不是「更干净」，是后面两件已知的事都要它：

- 搜索页/聚合海报墙要的是**同一份**元信息，放 model 上才不用各拉一次；
- 详情页顶部与选集卡片要共用 —— 都从 model 取，就不存在「谁传给谁」。

顺带把一条不做的事也定了：**不加 TTL、不做失效**。缓存是**进程内会话缓存**，以片名为键；
进程重启就没了，TMDB 元信息本身也不按分钟变。真要「强制重刮」，把「⋯」里的刮削开关
关掉再打开即可（那会清掉这一片的缓存）。

### 落地三步（照着做，不用再决策）

1. `AppModel+Metadata.swift`：加一个缓存 + `func metadata(for title: String, mode: PosterMode) async -> TMDBBundle?`
   —— 先查缓存，没有就 `search` + `backdrops` 拉一次并**存下**；同一片名并发请求要合流。

   **⚠️ 一处签名上的修正（写代码前先看这条）**：不要缓存「元信息 + 图集数组」——
   图集的元素类型本地读不到（`backdrops(kind:id:)` 的返回类型没在任何一处显式写出来，
   现有代码都是 `(try? …) ?? []` 直接喂给 `TMDBPosterSet`）。
   所以**缓存 `TMDBMetadata` + 已经建好的 `TMDBPosterSet`**，并记下建它时用的 `mode`：
   - 命中条件 = 片名相同**且** mode 相同；
   - mode 不同就重建（换模式是低频操作，多一次请求可接受）。
   这样只依赖三个**已知**类型（`TMDBMetadata` / `TMDBPosterSet` / `PosterMode`），
   不靠猜类型名 —— 猜错了本地编译不了、只有 CI 能发现。
2. `TMDBDetailHeader`：把内部那套 `@State` + `load()` 换成调 model；它只剩「画」和轮播的
   `step` 步进（那是视图级的定时行为，仍归它）。
3. `embyEpisodeCard` 接图：`image(step: index, seed: seed &+ UInt64(index))`，
   卡片尺寸与选集区骨架高度一起改（现在 92×48）。

### 为什么先定再写

第 2 步要动 `TMDBDetailHeader` 的加载，第 3 步要动另一个视图的卡片 —— **两边一起改才自洽**。
分两笔提交、中间夹一段「一边新一边旧」的状态，真机上一眼就是半成品。

## 已知风险（编译/真机时先看这几条）

- `TMDBDetailHeader` 里 `URLSessionTransport()` 是**按需新建**的。
  若它要求参数、或 model 已有共享实例 → 改成复用。这类「接口形状猜错」本地静态检查抓不到。
- 详情页顶部的 `TMDBDetailHeader` 与 `embyHeader` 的封面**可能同时显示两张**（见片 3）。
- `progress.episodeIndex` 与当前线路可能对不上 —— 越界已回落到第一集（`playSlot`）。

## 未偿债

- **M11 约 25 条测试从没跑过**：本机无 Swift 编译器，只有 CI 能验。
  按 YG 的顺序：**先把功能做完，CI 最后**。
- 每片提交前跑：`check_braces` / `check_lint` / `audit_duplicate_types` / `swiftformat`。
  **红着不提交**（这条纠正过两次）。

## PlaybackView 的 `model` 越界（CatVodUI 首次编译暴露，待修）

那文件的设计是**只收值 + 闭包**（`danmaku` / `onDanmaku` / `onStart`，注释明写「播放页不拿 `AppModel`」）。
M08/M09/M10 往上接弹幕 / 字幕 / 下载时直接引了 `model`，8 处编译不过（`cannot find 'model' in scope`）。

**修法是传值 + 闭包，不是把 `AppModel` 递进去** —— 递进去就是把这条设计作废。

### 要加的参数（**都带默认值**，7 个现有构造点因此一行都不用动）

| 用途 | 现在 | 改成（名字可调，类型名以实际声明为准） | 使用处 |
| --- | --- | --- | --- |
| 字幕显示设置 | `model.subtitleDisplay` | `let subtitleDisplay: SubtitleDisplayConfig` | 182 / 185 |
| 字幕 cue | `model.subtitleCues` | `let subtitleCues: [SubtitleCue] = []` | 215 / 228 |
| 弹幕行 | `model.danmakuLines` | `let danmakuLines: [DanmakuLine] = []` | 240 / 260 |
| 弹幕显示设置 | `model.danmakuDisplay` | `let danmakuDisplay: DanmakuDisplayConfig` | 248 / 264 |
| 批量下载 | `await model.enqueueDownloads(...)` | `let onEnqueueDownloads: (([DownloadRequest]) async -> Int)?` | 299 |

### 构造点（7 处，都已存在）

`LiveScheduleView:75/86`、`LiveView:386`、`ParsePlaybackView:47`、`SettingsView+DataPages:97`、
`SitePlayEpisodeView:61`、`VodDetailView:657`

→ 只有 **VodDetailView** 与 **SitePlayEpisodeView**（手里有 `model`）传真值，其余走默认值。

### 顺带

`PlaybackView:241` 的 `the compiler is unable to type-check this expression in reasonable time`
就在 `danmakuPlanKey` 里 —— 把那个数组拆成局部变量后，大概率一起消。
