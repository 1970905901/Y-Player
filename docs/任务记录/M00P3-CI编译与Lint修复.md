# M00P3 CI 编译与 Lint 修复（本轮）

- 状态：修完已知三类错误，**等 CI 复跑确认**；本地看门人全部重建
- 时间：2026-10-09
- 前序：`M00P1-CI-Lint修复.md`、`M00P2-全量格式化.md`

## 一、CI 报了什么

第一轮 `build` 红在 `SwiftPM tests` 的第一个 job（CatVodCore）：

```
CatVodCore/Vod/Danmaku/DanmakuSource.swift:35: error: 'DanmakuSource' is ambiguous for type lookup
  note: found this candidate: MediaExtras.swift:63
```

修掉之后立刻暴露下面两层（**它们本来就在，只是被前一个错挡住了**）：

| # | 错误 | 位置 | 修法 |
| --- | --- | --- | --- |
| 1 | `'DanmakuSource' is ambiguous for type lookup` | 两个顶层同名类型 | 合并成一个（见下） |
| 2 | SwiftLint `shorthand_operator` | `DanmakuAPI.swift:58` | `x = x + y` → `x += y` |
| 3 | `multi-line string literal content must begin on a new line` | `DanmakuLineTests.swift:126` | `"""…"""` 当单行用 → 改原始字符串 `#"…"#` |

**关于第 1 条**：两份 `DanmakuSource` 都是「上游 `bean/Danmaku.java`」的建模，但谁都不完整 ——
一份在弹幕取用链上（活的，有 `array(from:)` 解析），另一份只被 `SpiderResult.danmaku` 的**声明**引用
（没有任何生产消费方，字段还少了 `source`）。所以不是删一个，是**合并成一个**，
并把那份里的 `extras` **丢掉** —— 它 `init(from:)` 里是 `extras = [:]` 硬写空数组，
从没被真正解析出来过（grep 全仓确认无人读）。详细的表格在提交信息里。

**关于第 3 条**：这个坑本项目记过一次（「`"""` 当单行用」），还是踩了 ——
因为踩的时候本地没有任何东西会报它。

## 二、为什么本地一路绿灯（本轮真正的收获）

**本地没有 Swift 工具链**，所以三类问题本地全都看不见：

- 编译器错误（同名类型、语法细节）—— `swiftformat` 只做**语法**解析，不做类型检查；
- SwiftLint 违规 —— Windows 上没有 SwiftLint（它要 Swift + SourceKit）；
- **而原本负责「代替 SwiftLint」的那个脚本，本身就是坏的**：`check_lint.py` 的检查清单是
  硬编码的文件列表，里面还留着改过名的 `SpiderEpisodePlaybackView.swift` ——
  它读不到文件**当场抛异常**（这次真崩了），而新文件（`DanmakuAPI.swift`）压根不在清单里。
  也就是说：它既会崩，又覆盖不到，还给人「跑过了」的错觉。

## 三、重建了三个本地看门人

| 脚本 | 之前 | 现在 |
| --- | --- | --- |
| `check_lint.py` | 硬编码清单（会崩、覆盖不到） | **全仓扫描**，只留高置信度规则：`force_unwrapping` / `empty_string` / `shorthand_operator` / `first_where` / `last_where` / `sorted_first_last` / `array_init` / `toggle_bool` / `redundant_nil_coalescing` / `fatal_error_message` / `line_length` |
| `audit_duplicate_types.py` | 不存在 | **新增**：按模块找顶层同名类型（就是第 1 条那类错）。判据排除嵌套同名（`CodingKeys` 合法）与同一文件里的 `#if` 分支 |
| `collect_changed.py` | rename 会被解析成畸形路径 | 按状态码跳过 rename 的第二个 NUL 项（提交时踩到过，`git add` 报「路径不存在」） |

**关于 lint 规则的分工**（第一版补太狠，175 条命中几乎全是误报，教训）：

- 纯空格类（冒号 / 逗号）交给 **SwiftFormat** —— 它本地能跑，而且已经 0 违规；
- 语义类（`identical_operands` / `contains_over_filter_count` / `toggle_bool` 的一般情形）
  需要语法树，朴素匹配必然误报 —— **宁可不做**，等 CI 报；
- 剩下的收窄后是 3 条命中，而且都指向真问题：测试里的 `== ""` 改成 `.isEmpty`。

## 四、机制上的教训

1. 本地看门人必须**跟着全仓**，不能维护文件清单 —— 清单一定会过期，而过期的方式是**静默不覆盖**；
2. 「跑过了」和「跑到了」是两件事：脚本崩了如果没看输出，跟跑绿了一样；
3. 这类错误的代价不只是修一次 —— 它**挡住整个 job**（后面 CatVodNet / Source / Player / Store / UI / Node 全是 skipped），
   所以一次只能看到一个错误，只能一轮轮迭代。这也是为什么要把它**工具化**：
   `audit_duplicate_types.py` 现在能在本地一次扫完全部同类问题。

## 五、还没确认的

- `SwiftPM tests` 复跑是否还有**后面几层**的编译/测试错（本地看不出来）；
- `Build apps (unsigned)` / `Unsigned IPA` / `Release` 三个 job **从没真正跑过**（一直被前面挡住），
  它们本身的构建脚本是否可用也要等这一轮结果。

CI 复跑结果出来后按同样方式继续：**先工具化定位，再修**。
