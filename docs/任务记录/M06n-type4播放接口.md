# M06n `type=4` 站点的 play 接口（Source 层已通，UI 未接）

- 状态：**已闭环**（Source 层 + 详情页接线）；11 条单测钉住 play 请求与响应，视图层那三处靠调用点审查（见第五节）
- 时间：2026-10-09
- 依赖：`PlayRequestBuilder`（请求构造，早已就位）

## 一、怎么发现的

详情页的 `unsupportedReason` 里有一句「该集需要经 `type=4` 的 `play` 接口中转（**尚未实现**）」，
而矩阵把 `type=4 HTTP + base64 ext` 标成 ✅ 完整 —— 两者矛盾，顺着查下去：

`PlayRequestSource.http` 全仓只有三处出现：**构造它的** `PlayRequestBuilder`、
**告诉用户尚未实现的**详情页、以及断言构造正确的单测。
**没有任何地方发送这个请求** —— 又一个「能读、没人用」，这次是「能构造、没人发」。

后果很具体：`type=4` 站点（`kind == .httpApiBase64Ext`）的**每一集**都播不了。

顺带查出 `SiteClient.play` 的注释写反了方向：它写「CMS 站点…**没有独立 play 接口**」，
把一个「我们没实现」说成了「上游不需要」。上游是需要它的（下一节）。

## 二、上游依据（取源码核对，不猜形状）

`SiteApi.playerContent` 的 type==4 分支（`Tools/out/upstream/SiteApi.java`；该目录不入库，片段抄在下面）：

```java
} else if (site.getType() == 4) {
    ArrayMap<String, String> params = new ArrayMap<>();
    params.put("play", id);
    params.put("flag", flag);
    String playerContent = call(site, params);   // call() 里补 extend=site.ext
    Result result = Result.fromJson(playerContent);
    if (result.getFlag().isEmpty()) result.setFlag(flag);
    result.setUrl(Source.get().fetch(result));
    result.setHeader(site.getHeader());
    result.setKey(key);
    return result;
}
```

四个要点，都已在实现里对齐且各有测试：

| 要点 | 上游行为 | 我们的落点 |
| --- | --- | --- |
| 参数 | `play` + `flag`（外加 `call()` 补的 `extend`） | `PlayRequestBuilder.httpPlayRequest` ✓（本来就对） |
| 响应形状 | `Result.fromJson`：`url` / `parse` / `jx` / `header` / `msg` / `flag` / `format` … | 直接解成 `SpiderResult` ✓（字段早已齐备） |
| `flag` | 响应给了就用响应的，没给才回填请求的 | `CMSClient.play` 里回填 |
| `header` | `setHeader(Map)` 是 `if (getHeader().isEmpty())` ⇒ **响应优先** | 我们的 `HTTPHeaderMerger.merge([site.header, result.header])` 正好后者覆盖前者 ✓（不用改） |

响应里 `url` 的**三种形态**（字符串 / 成对数组 / 对象 `{values,position}`）上游用 `UrlAdapter` 处理，
我们这边 `PlaybackURLs` 早就支持同样三种（含 `{n,v}` 短键），所以这次一并测了。

`parse` 的缺省值是 **0（直链）** —— 对齐上游 `getParse()`：`parse == null ? 0 : parse`。
这点容易搞反（直觉上「没说就按需要解析处理」更保守），按上游来。

## 三、实现

- `CMSClient.play(site:flag:playID:)`：构造请求 → `perform` 发送解析 → 回填 `flag`。
  **第一行先校验类型**：`perform` 的白名单包含全部 CMS 类型，不先拦住的话 `type 0/1/2` 也会真的把请求发出去；
- `SiteClient.play` 的 `.cms` 分支从「抛 unsupported」改成调用它；类型不对时仍抛 `unsupported`。

## 四、测试

`CMSPlayTests` 十一条：请求形状（含「不带 `ac`/`ids`」）、`extend` 注入、直链、`parse=1`、`jx=1`、
`parse` 缺省、`flag` 回填与保留、`url` 三形态、响应 header 保留、
**类型不对时一颗请求都不发**、非 2xx、畸形 JSON。

## 五、详情页接线（同一笔的后半）

三处改动，把上面的 Source 层接进播放流程：

1. **`ParsePlaybackView.parseContext()` 的 `webURL` 改成 `detail.url.selected?.url ?? episode.url`** ——
   这是整条链能一次闭环的关键。解析链的待解析地址本来就取「结果里的 url」，改成优先取它之后：
   详情页那条路径的 detail 不带 url，自动回退到选集地址（**行为不变**）；
   而 play 场景把 **play 的结果**当 detail 传进来，解析链就直接用 play 换来的地址 ——
   等价于上游「把 `result` 一路往下传」，不需要另造通道；
2. **`SpiderEpisodePlaybackView` 改名 `SitePlayEpisodeView`**：它本来就是「先异步换地址再播」，
   `type=3` 与 `type=4` 共用，名字不该只写 Spider。顺带补上 `parse/jx = 1` 的出路
   （以前会直接拿那个「还需要解析」的地址去播）；
3. **`VodDetailView.destination` 加 `type=4` 分支** + `requiresSitePlay(_:episode:)` 判定
   （与 `canParse` / `makeResource` 同一种写法：都拿 `PlayRequestBuilder` 的结果说话，
   不按站点类型猜）。`unsupportedReason` 里那句「尚未实现」随之变成不可达分支的兜底文案。

⚠️ 视图层这三处**没有自动化测试**（项目里视图逻辑一贯如此），但它们依赖的两块都有：
`CMSClient.play` 十一条单测、`ParseJobResolver` 自己的测试。

## 六、遗留

1. 多值 `url` 目前只取 `position` 指向的那条（与上游 `v()` 一致）；
   上游还有多线路切换（`Url.isMulti()`），没做；
3. 上游 `Source.get().fetch(result)` 那一层（迅雷 / YouTube / 电视猫等特殊 extractor）没对齐，我们只取 url。
