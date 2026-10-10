# M08a GRDB 落库（收藏与播放进度）

- 状态：Lint ✅；SwiftPM tests 的修复过程见 `M08b-存储接线.md` 的「验证记录」
- 时间：2026-10-07
- 范围：M8 第一步 —— 用 GRDB（SQLite）替换 M2 的内存实现，让收藏与播放进度**跨重启留存**；本轮不动 UI 接线
- 前置：M02（`FavoriteStore` / `PlaybackProgressStore` 协议）、M02P8（进度落库节流）

## 一、产出

| 件 | 说明 |
| --- | --- |
| `CatVodStore/GRDBDatabase.swift` | 持有 `DatabaseQueue`、跑迁移、提供 `read`/`write` 包装（失败留痕） |
| `CatVodStore/GRDBFavoriteStore.swift` | ``FavoriteStore`` 的 GRDB 实现（写入/读取/单条与批量删除/计数） |
| `CatVodStore/GRDBPlaybackProgressStore.swift` | ``PlaybackProgressStore`` 的 GRDB 实现（含元数据 JSON 列） |
| `CatVodStore/StorageFailureRecorder.swift` | 失败留痕（协议方法不 throws，但仓库不许静默失败） |
| `PlaybackEntryMetadata` | 增加 `Codable`：元数据整块以 JSON 文本存一列，避免为展示字段频繁改表 |
| `ThirdParty/grdb.lock.json` | 依赖锁定留痕（GRDB.swift 7.11.1 / MIT / exact pin / 用到的 API 清单） |
| `CatVodStoreTests/GRDBStoreTests.swift` | 4 例：收藏往返与排序、删除（单条/批量/空数组）、进度往返与元数据、**关库重开数据仍在** |

## 二、设计取舍

1. **表结构**：`favorite` 与 `playbackProgress` 都以 `vodKey`（`站点 key#视频 ID`）为主键，
   并**冗余存** `siteKey`/`vodID` 两列 —— 读时不必反解字符串，后续也便于按站点清理/统计。
2. **时间存 `REAL`（`timeIntervalSince1970`）**：显式化表示，避免 GRDB `Date` 编解码策略的隐式差异
   （官方文档也建议对 Date 表示做显式选择）。
3. **写操作一律 `INSERT OR REPLACE` / `DELETE`（不用 upsert 语法）**：语义直白，SQLite 版本要求最低。
4. **批量删除逐条执行**：不用 `IN (?, …)`，避免占位符上限与 SQL 拼接；「追剧」页多选删除量级很小。
5. **失败不抛给协议**：`FavoriteStore`/`PlaybackProgressStore` 的方法不 throws（M2 契约，UI 不为存储失败到处分支），
   因此统一记进 ``StorageFailureRecorder``（`NSLock` + `@unchecked Sendable`，调用点在同步闭包里不能 `await`）。
   设置页/诊断可显示「存储最近失败 N 次」——留痕但不打断播放。
6. **迁移用 `DatabaseMigrator`**：`CREATE TABLE` 只出现在迁移里，后续加字段追加一次 `registerMigration` 即可。
   顺带把 `AppDatabase` 用到的 `site` / `searchHistory` 两张表一起建好，M08b 接 UI 时不必再改迁移。

## 三、明确未做

1. **UI 接线**（把 `AppModel.favoriteStore`/`progressStore` 换成 GRDB 实现、设置页显示存储状态）：属 M08b。
   本轮只交付可单测的存储层，避免「存储 + 界面」一起改导致定位困难。
2. **iCloud/跨设备同步**：设置页入口仍为占位说明（M8 之后）。
   → **2026-10-10 拍板不做**（没有开发者账号）：这一区整块删掉（开关 / ID / 占位说明）。
3. **`AppDatabase` 协议**（站点清单/搜索历史）的 GRDB 实现：表已建好，实现待 M08b。
4. `sqlite3` 加密、WAL 之外的调优：暂不需要（单机单进程访问）。

## 四、验收

- 单测：`CatVodStoreTests/GRDBStoreTests`（4 例，含「关闭后用同一路径重开，数据仍在」——
  这正是「杀进程即丢」的反证）。
- CI：Lint + SwiftPM tests（含确认 GRDB 依赖能解析并编译）。
- 人工（需真机/Mac，M08b 完成后）：收藏一部片 → 杀掉进程 → 重开，「追剧」里还在。

## 五、回滚

删除 `GRDBDatabase.swift`、`GRDBFavoriteStore.swift`、`GRDBPlaybackProgressStore.swift`、
`StorageFailureRecorder.swift` 与对应测试，去掉 `CatVodStore/Package.swift` 的 GRDB 依赖、
`ThirdParty/grdb.lock.json`，并把 `PlaybackEntryMetadata` 的 `Codable` 去掉即可；
`AppModel` 仍用内存实现，行为回到 M2。

## 六、验证记录

（CI 结果待补。）
