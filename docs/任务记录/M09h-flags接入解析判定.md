# M09h `flags` 接入解析判定（并修正它的语义）

- 状态：`flags`（上游 `vipFlags`）接进 `useParse` 判定，7 条新单测；不再登记为「不生效字段」
- 时间：2026-10-09
- 依赖：M05b / M05c（解析链）、M06m（当初把 `flags` 记成「无消费方」的那轮）

## 一、起因：矩阵里那句「无消费方」是错的

矩阵与 `ConfigCoverage` 一直写着：`flags` 是「播放页的 flag 选择菜单（配套
`FlagSelectionListener`）」，本平台没有这个菜单 → 不生效。这话从 M06m 一直挂到现在。

这轮去读上游 `Result.java`，发现 **`flags` 的真实语义是 `vipFlags`**，它有两个明确用途：

1. `Result.isUseParse()`（`Result.java:335`）：

   ```java
   if (!VodConfig.hasParse()) return false;
   return (getPlayUrl().isEmpty() && VodConfig.get().getFlags().contains(getFlag())) || getJx() == 1;
   ```

2. `SiteApi.java:148` 把它传给 spider：`spider().playerContent(flag, id, VodConfig.get().getFlags())`
   —— 上游 `Spider.playerContent` 的第三个参数就叫 `vipFlags`（`upstream-quickjs-Spider.java:97`）。

也就是说：它是「**配置声明要靠解析的线路标记**」，不是一个给用户点的菜单。第 2 条是宿主侧的事
（bundle 自己读配置就行），第 1 条是**我们该接的**。

## 二、原来的问题：两个判定混成了一个

上游有两个**不同**的判定：

| 上游 | 含义 | 我们 |
| --- | --- | --- |
| `Result.needParse()` | 结果**自称**要解析：`parse == 1 \|\| jx == 1` | `SpiderResult.requiresParsing` ✅ 一致 |
| `Result.isUseParse()` | **配置**认不认这条线路要解析（含 `flags`） | ❌ 没有；`useParse` 槽一直填的是上面那个 |

`ParsePlaybackView.parseContext()` 原本写的是 `useParse: detail.requiresParsing` —— 槽是对的
（`ParseContext.useParse` 的注释本来就写着「与上游 `ParseJob.start(result, useParse)` 的 `useParse`
同义」），但填进去的是**另一个判定的值**。后果：`flags` 永远不生效；而没被声明的线路也会去套默认解析器。

⇒ 本轮改成 `ParseResultValidator.usesParse(...)`，逐字对齐上游的三段式：先 `hasParse()`，
再（`playUrl` 空 && `flags` 含本线路），最后 `jx == 1`。

一处刻意的加固：**空线路名不匹配任何 `flag`**。`flags: ["", "youku"]` 这种配置下，不挡这一道
会把「没有线路名的直链结果」也判成要解析。

## 三、为什么必须与 `needParse()` 分开

两者回答的是不同问题：「这条结果要不要解析」vs「配置要不要先套默认解析器」。混用不会崩，
只会让**某些线路的解析莫名其妙不生效**（或者反过来多跑一遍解析链）—— 真机上极难分辨。
所以两边都有单测，其中一条专门钉「两者结果不同」的场景。

## 四、连带的清理

- `ConfigCoverage`：`flags` 从「不生效字段」里**移除**（连同 `flagsReason`）—— 它现在生效了，
  继续报只会误导用户；`Ignored` 的顺序注释同步更新；
- `ConfigCoverageTests`：期望从 4 个字段降到 3 个，并新增一条「`flags` 有值也不再报」；
- 矩阵那一行从 ⚠️ 改成 ✅，语义也写对（vipFlags，不是 flag 菜单）；解析链那一行补一句说明。

## 五、真机上要看什么

找一个**配置里有 `flags`、且这些线路的详情 `playUrl` 为空**的源：

1. 选那些线路播放 → 应该真的走解析链（出现解析页 / 能出播放地址）；M09h 之前它们会拿空地址去播 → 失败；
2. 反过来，**没被 `flags` 声明的线路**不该被塞进默认解析链（之前会）。

手上没有这样的源就先挂着 —— 这是「协议对齐」类改动，逻辑侧由单测钉住。
