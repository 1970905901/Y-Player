# M04P6 Libav 输入层（打开流 → 读流信息）

- 状态：**已实现**（本地静态闸门全绿 + 新单测；Mac 编译与测试待 YG）
- 时间：2026-10-10
- 触发：M04P5 引擎骨架就位后，真会话要做的第一件事是**能打开媒体、读出流信息** ——
  「自定义 headers 能不能真的进到 FFmpeg」「流信息读出来长什么样」这两件事
  不需要等画面就能验，而且它们错了后面全错。

## 一、做法

新增 `LibavInput`（**全工程第一个碰 libav 的文件**，M04P5 的分层承诺在这里兑现）：

| 方法 | 说明 |
| --- | --- |
| `open(url:headers:)` | `avformat_open_input`（headers 走 http 协议选项）+ `avformat_find_stream_info` |
| `mediaInfo()` | 时长（秒）+ 每条流的类别 / 编码名 / 分辨率；没打开给 nil |
| `close()` | **幂等**；`deinit` 兜底 |

三个细节：

1. **headers 映射是纯函数**（`httpOptions(from:)`，可单测）：`User-Agent`/`Referer` 走 FFmpeg 的
   专名选项（`user_agent`/`referer`，塞进 `headers` 串会产生重复请求头）；其余拼成
   `名: 值`（`\r\n` 分隔）交给 `headers` 选项，按名排序只为输出稳定。
2. **错误翻人话**：`av_strerror`（256 字节缓冲，FFmpeg 惯例）；失败路径统一走 `close()` 一个出口。
3. **流类别用字符串翻**（`av_get_media_type_string` → `"video"/"audio"/"subtitle"`），
   不在 Swift 里比对 C 枚举 —— 少一类跨编译器版本的互操作坑。

## 二、测试夹具：离线的小 MP4

`TinyMP4Fixture`（测试侧）：用 `AVAssetWriter` 现场编一个 320×240、30 帧的 H.264 MP4。

- **单测不打网络**（红绿看运气的事不干）——夹具是确定性的；
- M04P7 的 demux 测试接着用同一个夹具，不用再造。

## 三、故意没做

- **demux 循环 / 解码 / 渲染**：M04P7 起；
- `LibavInput` 暂未接进 `FFmpegSessionFactory`：等 demux 能动了再接线，
  那时才有真正的「打开 → 播放」路径可给引擎（现在接上只会造一个「能开不能播」的假会话）。

## 四、验证点（Mac）

1. `swift test --package-path Packages/CatVodPlayer`：新套件「Libav 输入层（M04P6）」3 条全绿
   —— headers 映射、打开不存在的文件（给错误描述不崩）、打开真实小文件（时长 / 分辨率 / 编码名）；
2. 全包测试 + App 编译照旧；
3. 行为上仍然零变化（`.ffmpeg` 不可选）。
