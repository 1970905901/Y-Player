# M06d HLS 广告清理（清单规则核心）

- 状态：清理器 + 规则编译**已实装并有单测**（本次提交）；**接到播放路径与设置开关是下一步**（见第五节）
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

## 五、明确未做（下一步）

1. **接到播放路径**：本地服务的 `/m3u8` 目前只做「代理 + 改写相对地址」，还没跑清理器。
   接法是给 `LocalProxyHandler` 注入一个「清单清理」闭包（启用哪些规则由上层决定），与 `upstream` 的注入方式一致；
2. **启用开关的落盘**：`HLSAdRuleState` 已经能算出「该不该开」，但存覆盖值的那份偏好
   （参考实现叫 `builtin_hls_rule_overrides`）与界面入口都还没做；
3. **内置规则包**：参考项目那份 `assets/rules/hls_rules.json` 现在是 **`rules: []`（空包）**，我们照样子先留空 ——
   内置规则要背「误杀率」的责任，参考项目自己的更新要求写着「至少一个应删 fixture + 一个反 fixture + 一个错误 host 反 fixture」；
4. **`legacy` 兜底规则**（按分片路径前缀分组、按不连续块时长差找广告那两套启发式）不做：
   它们比规则更「猜」，先要有实测数据。

## 六、验证记录

- 本地自查：`Tools/out/check_braces.py`（括号 / 连续空行 / 行尾空白）**干净**；
  `Tools/out/check_swift.py` 对本轮新代码只报三条**已知假阳性**，都已核对：
  ① `[shadow] 局部 fallback 与同文件方法同名` —— 其实是 `Result.fallback` **字段**与 `Result.fallback(_:)` **静态工厂**
  的合法重载（从不出现「局部遮蔽后调用静态方法」那种真错误，代码里一律写 `Result.fallback(…)` 限定）；
  ②③ 两条 `[toggle_bool]` —— 该规则要求 `x = !x` 这种同表达式自赋值，这里是 `let x = !y.isEmpty`（取反，不是自赋值）。
- 工具本身这轮修掉一个真问题：`check_swift.py` 以前把 Windows 工作副本的 CRLF 当成「行尾空白」，
  287 个文件报出 8658 条「问题」；现在先归一化行尾再判定（教训记在 `docs/构建与分发.md` 第 36 条）。
- CI：待跑（本轮按指示不盯）。
