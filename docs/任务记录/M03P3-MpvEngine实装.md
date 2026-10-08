# M03P3 MpvEngine 实装（方案第 4 步：先把 CI 能验的那半做完）

- 状态：**已提交、待 CI 验证**（本轮按指示未盯 CI；`LibmpvSession` 是盲写的 C 互操作，见第五节）
- 依赖：`M03P1-MPVKit落地方案.md` 第 1/2 步、M2 的 `PlayerEngine` / `PlayerCoordinator`
- 目标：把方案第 4 步的引擎落下来，同时**不假装「能用了」** —— 画面输出（第 3 步）还没定

## 一、分层：把「CI 验得了的语义」和「只能在真机验的画面」切开

方案第三节写过：CI 能验「协议实现是否完整、状态机是否正确」，不能验「画面出不出得来」。
所以引擎不是一坨直接调 C 的代码，而是三层：

| 文件 | 职责 | CI 能验？ |
| --- | --- | --- |
| `MpvSession.swift` | libmpv 的**最小接口**（seam）+ 我们自己的事件/值类型 | 协议本身 |
| `MpvEventMapping.swift` | 纯映射：属性 id ↔ 名 ↔ 格式、属性变化 → 效果、`end-file` 语义 | ✅ 单测全覆盖 |
| `MpvEngine.swift` | `actor`，实现 `PlayerEngine`：状态机 + 命令下发 + 事件循环 | ✅ 单测（假会话） |
| `LibmpvSession.swift` | **全工程唯一的 `mpv_*` 调用点**（薄壳）+ `MpvSessionFactory` | 只编译 |

关键收益：第 3 步的 PoC 定了渲染路径后，**只动 `LibmpvSession`**（补 `vo` 与 render API），
`MpvEngine` 与 seam 一行不改 —— 渲染路径的选择不会污染状态机。

## 二、语义清单（都有单测盯着）

| 动作 | 落到 libmpv |
| --- | --- |
| `load` | 先设选项（`hwdec` / `start` / `http-header-fields` / `sub-files`）→ `mpv_initialize` → `observe` 三个属性 → `loadfile <url> replace` |
| `play` / `pause` | `set pause no` / `set pause yes` |
| `seek` | `seek <秒> absolute` |
| `setRate` | `set speed <倍速>` |
| `selectTrack` | `set vid|aid|sid auto|no|<轨道 id>` |
| `teardown` | 取消事件循环 + `mpv_terminate_destroy`（**幂等**：引擎与 `deinit` 都可能调） |

观察的属性只有三个，各自的语义：

- `time-pos`（double）→ `timeChanged(current:duration:)`；负值 / 类型不对（mpv 会回 `MPV_FORMAT_NONE`）一律忽略 ——
  不能把「暂时没有值」当成「播到 0 秒」；
- `duration`（double）→ 记下来并补一条 `timeChanged`（进度条要立刻能画，此时位置还是 0）；
- `pause`（flag）→ 改状态；**加载途中来的变化忽略**，否则会出现「还没加载完就显示播放中」。

`end-file` 只有 `reason == "error"` 算失败：`stop` / `quit` 是我们自己 teardown / 换片时 mpv 报的，
对用户说「播放失败」是错的。

## 三、可用性：实装 ≠ 可用（这条最容易被绕过，所以用测试钉住）

- `MpvAvailability.isEngineImplemented` → **true**（引擎代码齐了）；
- 新增 `MpvAvailability.isVideoOutputReady` → **false**（渲染路径属第 3 步，需要 Mac/真机 PoC）；
- `PlayerEngineKind.mpv.isAvailable` = 两者**都**真 → 仍是 false；
- `PlayerCoordinator.makeEngine(.mpv)` 仍返回 nil，不可用原因改成
  「MPV 内核已实装（M3 第 4 步），但画面输出路径还没定（第 3 步需在 Mac/真机上做 PoC）—— 现阶段仍不可用」。

不这样做的后果很具体：`MpvEngine` 现在能把片加载起来、能播、能报进度，**但没地方显示画面**。
宣称可用就等于 M03P1 修过的那个坑（「依赖链接上了就当能用」）换个马甲再来一次。

## 四、测试

新增：

- `MpvEventMappingTests` —— 纯映射：属性三边一致（id ↔ 名 ↔ 格式，漏一个格式就是「observe 了但永远收不到值」的哑火）、
  `time-pos` / `duration` / `pause` 的效果、错误类型与负值的忽略、`end-file` 失败判定、属性值取用、等待超时上界；
- `MpvEngineTests` —— 假会话（`FakeMpvSession`）：load 的**调用顺序**（选项必须在 `initialize` 之前）、
  软解 / 起播位置 / header 拼串 / 不预设 `vo`、事件序列（`loading → playing → timeChanged`，顺序确定不靠 sleep）、
  `end-file` 两种结论、加载途中 `pause` 被忽略、七条命令的字面量、teardown 后能复用（每次 load 都销毁旧会话）、
  四条错误路径（URL 非法 / 无会话 / `initialize` 失败 / `loadfile` 失败）、以及**事件循环真的会消费会话事件**那圈胶水。

更新（旧断言写的是「引擎未实装」，现在语义变了，必须改）：

- `MpvAvailabilityTests`、`Tests/YPlayer-iOSTests/SimulatorSmokeTests.swift` → 断言改成「实装 + 渲染未定 → 仍不可用」，
  并检查不可用原因里能看出「不是没写，是渲染没定」。

## 五、已知未做 / 盲区（写给未来的自己）

1. **渲染**：`vo` 与 render API 一项没设，故意的（第 3 步定了再加）；
2. **真实 C 交互没在 CI 上手过**（能编译、能单测，但没跑过真 libmpv）。盲写处最可能出问题的三处，
   都在 `LibmpvSession.swift` 一个文件里，改起来不用动上层：
   - `mpv_command` 的指针数组：C 要 `const char **`，Swift 侧是 `UnsafeMutablePointer<UnsafePointer<CChar>?>`。
     现写法用 `Optional(UnsafePointer(...))` 显式建成 `[UnsafePointer<CChar>?]`（数组元素不会自动变可选）；
     若仍报类型不符，退路是 `mpv_command_string`（代价：要把 URL/参数转义进一条命令串）；
   - **C 枚举的导入模型**：`MPV_EVENT_*` / `MPV_FORMAT_*` / `MPV_END_FILE_REASON_*` 若是「结构体 + 全局常量」，
     `switch … case MPV_EVENT_FILE_LOADED` 就照现在这样写；若 clang importer 把它们导成了 Swift 枚举，
     符号形式会变成 `.fileLoaded` 之类 —— 只改本文件；
   - `mpv_create()` 的返回类型：`mpv_handle` 是不完整结构体时应为 `OpaquePointer`；若被导成
     `UnsafeMutablePointer<mpv_handle>`，把 `handle` 的声明类型换掉即可。
3. **`tracksChanged` 没发**：`PlayerEvent` 有这个事件，但 mpv 的轨道列表要么 observe `track-list`、要么
   `mpv_get_property`，两者都得在真机上对齐语义。当前 `selectTrack` 只**下发选择**、不**上报列表** —— 明确记录，别当成 bug；
4. **`hwdec` 只用 `auto-safe` / `no`**：`auto-safe` 之外的策略（如强制 `videotoolbox`）等真机测性能时再定；
5. **`shutdown` 事件不改状态**：它只在我们自己销毁时出现（`teardown` 已把状态置回 `idle`）。

## 六、后续

1. 第 3 步 PoC（需要 Mac/真机）：三选一后 → `LibmpvSession` 补 `vo` + render API →
   `isVideoOutputReady = true` → `PlayerCoordinator.makeEngine` 放开 `.mpv`；
2. 真机第一件事仍是确认 App 能启动（动态库嵌入失败会以 `dyld` 暴露，CI 只编译验不到）；
3. 真机跑通后再补 `tracksChanged` 与字幕/音轨切换的实测对照；
4. M4 的 `FFmpegEngine` 复用同一套分层（seam + 纯映射 + actor 状态机），不引第二份 FFmpeg。
