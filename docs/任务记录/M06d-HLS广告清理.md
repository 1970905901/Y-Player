# M06d HLS 广告清理（清单规则核心）

- 状态：清理器 + 规则编译 + **`/m3u8` 播放路径接线**都已实装并有单测；**启用开关落盘、内置规则包与「跳过广告」提示**是下一步（见第六节）
- 时间：2026-10-08
- 依赖：M06c（`/m3u8` 清单改写 + 本地服务）、参考项目 webhtv 的
  `utils/HlsManifestCleaner.java`、`bean/HlsAdRule.java`、`bean/HlsRulePackage.java`、
  `bean/HlsRuleState.java`、`api/config/HlsRuleConfig.java` 与它自己的 `docs/hls-rule-sources.md`

## 一、为什么不是「把 hlsRules 套上就完事」

接口配置里的 `hlsRules`（``HlsRule``：`hosts` / `regex` / `exclude`）从 M2 起就只有模型、没有消费点。
翻参考实现才发现那套东西是**两层**：

| 参考实现 | 本项目 |
| --- | --- |
| `HlsAdRule` + `HlsRulePackage`（带 `schemaVersion` 的规则包；字段多、默认关闭、另有来源与更新要求文档） | `HLSAdRule` + `HLSAdRulePackage`（本次） |
| `HlsManifestCleaner`（**信号制**清理器，删片段前过六道安全阀） | `HLSManifestCleaner`（本次，逐条对齐） |
| `HlsRuleConfig#compileLegacyRules`（把配置里的 `hosts`/`exclude` 当一条手工规则） | `HlsRule.compiledAdRule()`（本次） |

也就是说：**配置里那对 `hosts`/`exclude` 只是「一条手工规则」**，真正的清理器是另一套。
所以这一轮先把「清理器 + 规则编译」落地（纯逻辑、可测、无副作用），下一轮才谈接线 ——
否则又会出现「规则能读、但谁都没在用」的空响。

## 二、清理器（逐条对齐 `HlsManifestCleaner`）

- **信号制**：分片 host 后缀 / 分片 URL 正则 / 时长区间 / `#EXT-X-DISCONTINUITY` / 跨域 ——
  一条规则要凑够 `minimumSignals` 个**互相独立**的信号才算命中，一个信号不够就不删；
- **作用域**：规则可限定清单 host（后缀或正则）；不限定就命中所有站点，所以 ``HLSAdRule/compile()`` 强制要求作用域；
- **只删完整条目**：`#EXTINF` + 地址才算一个片段；孤立标签、半截条目原样留着；
- **六道「宁可不删」的安全阀**：字节范围清单、低延迟清单（`#EXT-X-SKIP:` / `PART:` / `PRELOAD-HINT:`）、
  删除比例 > 35%、删除总时长 > 90 秒、直播清单里删中间段、序列号会溢出；
- 命中时连带丢掉片段前面的 `#EXT-X-DISCONTINUITY` / `#EXT-X-PROGRAM-DATE-TIME`
  （**保留** `#EXT-X-KEY` / `#EXT-X-MAP`），直播清单还要把
  `#EXT-X-MEDIA-SEQUENCE` / `#EXT-X-DISCONTINUITY-SEQUENCE` 往前推。

## 三、规则与状态

- `HLSAdRule`：JSON 形态，字段与参考实现一一对应；``compile()`` **不合法就抛**
  （缺 id、没作用域、`minimumSignals` 越界、时长只给一半、危险正则、空正则）——
  绝不降级成更宽松的规则：规则一放宽，误删的就是正常内容；
- 危险正则判定（连续 `.*` / 嵌套量词）+「最多 32 条、单条 ≤ 512 字符」两道闸照搬；
- `HLSAdRulePackage`：**只认 `schemaVersion == 2`**；坏 JSON / 版本不认识一律当空包（不按认得出的字段凑合）；
- `HLSAdRuleState`：状态键 `来源:源标识摘要:规则 id`（源标识摘要后再进键，接口地址带 token 也不能漏出去）；
  生效值 = **本地开关 > 规则建议默认值 > 关**。
  与参考实现唯一的差别：它用 SHA-256 前 8 字节，本项目复用仓库已有的 ``MD5``（Core 里没有 CryptoKit），
  同样取 16 个十六进制字符 —— 这个键只是**本地偏好键**，不需要与上游互通。

## 四、测试

- `HLSManifestCleanerTests`：**14 条，逐条对齐参考实现的用例**（两信号命中、不命中不动、比例超限、
  主清单、半截片段、信号数不够、跨域+不连续块、直播删开头并推进两个序号、直播删中间段放弃、
  `DISCONTINUITY-SEQUENCE` 不算边界、跨 `#EXT-X-KEY` 不重复计、字节范围、总时长超限、多条规则算第一条）；
- `HLSAdRuleTests`：JSON 编出来能用 + 该拒的六种都拒 + 坏 JSON 解析成「没配」；
- `HLSAdRulePackageTests`：版本只认 2、空包、内置默认关闭、状态键形状（源标识不进键）；
- `HlsRuleCleanerMappingTests`：配置规则映射（`hosts` 当作用域、`exclude` 当分片正则）、空 `exclude` 跳过、id 稳定。

## 五、接线（`/m3u8` 真的用上规则了）

这一轮一起把消费点接上，否则清理器就是又一个「写好了没人调用」：

| 件 | 改动 |
| --- | --- |
| `LocalProxyHandler` | 新增 `adRules: @Sendable () -> [HLSManifestCleaner.Rule]`（默认空数组）；清单流程变成「取上游 → **清理** → 改写相对地址 → 回客户端」 |
| 顺序（**关键**） | 清理必须在**改写之前**：规则里的 host / 域名说的是**上游**地址，改写完之后这里只剩 `127.0.0.1`，规则会一条都匹配不上 |
| `HLSAdRuleStore`（Core） | 规则的「当前生效值」小盒子（`NSLock` + `@unchecked Sendable`，理由同 `StorageFailureRecorder`）；本机服务**每个请求读一次** |
| `AppModel` + `AppModel+LocalProxy` | 配置加载成功后 `refreshAdRules()` 把 `SourceConfig.hlsRules` 编译进盒子；规则提供者闭包**只捕获盒子、不捕获 AppModel**（它在线程池里被调用，碰主线程状态就是数据竞争） |
| 配置换了怎么办 | **不重启本机服务** —— 换个源之后 `/m3u8` 下一次请求读到的就是新规则（重启会换端口，正在播的那条链路会断） |

没配规则的部署行为与 M06c 完全一致：清理器拿到空规则数组会直接原样返回（`Result.unchanged`）。

## 六、明确未做（下一步）

1. **启用开关的落盘与界面入口**：`HLSAdRuleState` 已经能算出「该不该开」，但存覆盖值的那份偏好
   （参考实现叫 `builtin_hls_rule_overrides`）与设置页入口都没做。
   注意语义差别：**接口配置里的 `hlsRules` 是「用户自己写的规则」，一律生效**（对齐参考实现的 legacy 路径）；
   `HLSAdRule.enabled` 那套「默认关闭、要显式打开」说的是**规则包**（内置/外来的），等做规则包时再一起做；
2. **内置规则包**：参考项目那份 `assets/rules/hls_rules.json` 现在是 **`rules: []`（空包）**，我们照样子先留空 ——
   内置规则要背「误杀率」的责任（参考项目自己的更新要求：至少一个应删 fixture + 一个反 fixture + 一个错误 host 反 fixture）；
3. **「跳过广告」提示**：参考实现有 `HlsAdblockNotice`（界面上提示这次跳了多少秒），我们只把统计放在
   `Result` 里没往上带 —— 要显示就得让 `/m3u8` 把结果回传给界面，属另一条链路（等有真机数据再谈）；
4. **`legacy` 兜底规则**（按分片路径前缀分组、按不连续块时长差找广告那两套启发式）不做：
   它们比规则更「猜」，先要有实测数据。

## 七、验证记录

- 本地自查：`Tools/out/check_braces.py`（括号 / 连续空行 / 行尾空白）对 121 个文件**0 问题**；
  `Tools/out/check_swift.py` 对本轮新代码只有三条**已核对的假阳性**（`Result.fallback` 字段与静态工厂的合法重载、
  两条 `let x = !y.isEmpty` 被误判成 `toggle_bool`）。
- 工具这轮修掉两个假阳性：`check_swift.py` 把 Windows 工作副本的 CRLF 当「行尾空白」（287 个文件报 8658 条）；
  `check_braces.py` 不认原始字符串 `#"…"#`，把含引号的 JSON 片段当「字符串提前结束」，害得四个老测试文件一直挂着
  「圆括号不平衡」的假告警（教训记在 `docs/构建与分发.md` 第 36 条）。
- CI：待跑（本轮按指示不盯）。
