# js2p 宿主契约（实测）

- 数据来源：`https://9280.kstore.vip/ceshi/index.js`（**6,291,879 字节**，`text/javascript`）
- 校验：远端 `index.js.md5` = 本地摘要 = `35dcc10d533153dbb94298792664ad04` ✅
- 分析方法：`python Tools/analyze_js2p.py`（产出 `Tools/out/js2p-report.txt`）
- 分析日期：2026-10-07

## 一、结论（M1.5 决策门）

**该 bundle 是「真 Node 服务端程序」，不可能由 JavaScriptCore + Node shim 承载。**

`require` 清单实测（出现次数）：

| 依赖 | 次数 | 依赖 | 次数 |
| --- | --- | --- | --- |
| `node:crypto` / `crypto` | 36 / 19 | `zlib` / `node:zlib` | 9 / 2 |
| `util` / `node:util` | 14 / 10 | `fs` / `node:fs` / `node:fs/promises` | 8 / 4 / 3 |
| `stream` / `node:stream` | 12 / 9 | `path` / `node:path` | 8 / 7 |
| `node:http` / `http` | 10 / 3 | `worker_threads` | 3 |
| `node:https` / `https` | 6 / 4 | `net` / `node:net` / `tls` / `node:tls` | 2 / 2 / 1 / 1 |
| `node:events` / `events` | 10 / 5 | `node:dns` / `dns/promises` | 2 / 1 |
| `node:assert` / `assert` | 8 / 5 | `http2` / `node:http2` | 2 / 1 |
| `buffer` / `node:buffer` | 3 / 2 | `node:diagnostics_channel` | 3 |
| `node:async_hooks` / `node:perf_hooks` | 2 / 1 | `node:timers/promises` | 3 |

打包的 npm 依赖（来自 esbuild 许可块）：**fastify 5 生态**（`forwarded`、`proxy-addr`、`toad-cache`、`fast-json-stringify`、`ajv`）+ `node-fetch` + `pako` + `cookie`。

决策：

- ❌ 路线 A（JSC + shim）**不可行**：`net`/`tls`/`dns`/`http2`/`worker_threads`/`fs`/`perf_hooks` 无法用 shim 覆盖。
- ✅ **路线 B（采用）：随包内嵌真 Node** —— macOS 随包 `node` 可执行文件（或 libnode），iOS 用 **nodejs-mobile libnode（Node 18.20.4）**。
- ❌ 路线 C（运行时下载 libnode + dlopen）：未签名 IPA 侧载后无法加载事后下载的 dylib。

## 二、启动契约（逐字实测）

```js
var Wh = null;
async function xq0(e = sq0) {
  Wh && await cq0();
  let t = async n => {
    try {
      console.log("messageToDart", n?.action || "");
      let x = typeof globalThis.catDartServerPort == "function" ? globalThis.catDartServerPort() : 0;
      return x ? (await r0.post(`http://127.0.0.1:${x}/msg`, n, { timeout: TAr(n?.action) })).data : null;
    } catch (x) { return console.error(x), null; }
  };
  globalThis.messageToDart = t;
  Wh = await aq0({ config: e, logger: process.env.NODE_ENV !== "development",
                   serverFactory: typeof globalThis.catServerFactory == "function" ? globalThis.catServerFactory : void 0,
                   messageToDart: t });
  Wh.address = function () {
    let x = this.server.address();
    return x && typeof x == "object" && (x.url = `http://127.0.0.1:${x.port}`, x.dynamic = "js2p://_WEB_"), x;
  };
  await uq0(Number(process.env.DEV_HTTP_PORT || process.env.PORT || 9988));
}
async function uq0(e) {
  let t = process.env.HOST || "0.0.0.0";
  try {
    await Wh.listen({ port: e, host: t });
    let n = Wh.server.address(), x = typeof n == "object" && n ? n.port : e;
    console.log(`CatVodSpiderios listening on http://127.0.0.1:${x}`);
  } catch (n) {
    if (n?.code === "EADDRINUSE") return console.log(`Port ${e} is already in use. Trying next available port...`), uq0(e + 1);
    throw console.error(n), n;
  }
}
function TAr(e) { return e === "queryProfile" ? 1200 : e === "saveProfile" ? 3e3 : 1e4 }
RAr() && xq0().catch(e => { console.error(e), process.exit(1) });
function RAr() {
  return process.env.CATVOD_DISABLE_AUTOSTART === "1" || typeof globalThis.catServerFactory === "function"
    ? false
    : /(?:^|[\\/])index\.js$/i.test(process.argv[1] || "");
}
0 && (module.exports = { start, stop });
```

要点：

1. **自启动条件**：未设 `CATVOD_DISABLE_AUTOSTART=1`、未注入 `catServerFactory`、且 `process.argv[1]` 以 `index.js` 结尾。
   → 我们用真 Node 执行 `node <cache>/index.js` 时**满足条件，服务自启，无需实现 `catServerFactory`**。
2. **端口**：`process.env.DEV_HTTP_PORT || process.env.PORT || 9988`；`HOST` 默认 `0.0.0.0`（宿主应注入 `127.0.0.1`）；`EADDRINUSE` 会自动 +1 重试。
3. **就绪信号**：stdout 固定打印 `CatVodSpiderios listening on http://127.0.0.1:<port>`，可直接解析实际端口。
4. **服务框架**：fastify 5（`Wh.listen({port,host})` / `Wh.server.address()` / `Wh.close()`；`serverFactory` 是 fastify 的同名选项）。
5. **宿主回调（可选）**：`globalThis.messageToDart(payload)` 仅在宿主提供 `catDartServerPort()` 时才 POST 到 `http://127.0.0.1:<port>/msg`，否则返回 `null`；超时按 action 区分（`queryProfile` 1.2s、`saveProfile` 3s、其余 10s）。
6. **模块化用法**：`module.exports = { start, stop }`，宿主亦可 require 后自行接管。

## 三、路由契约（逐字实测）

```js
for (let f of n) {
  await o10(e, f, `/spider/${f.meta.key}/${f.meta.type}`);
  await o10(e, f, `/spider/${f.meta.key}`);
}
async function o10(e, t, n) {
  await e.register(async x => {
    x.post("/init", t.init?.bind(t) || $zt);
    t.support && x.post("/support", t.support.bind(t));
    t.home && x.post("/home", t.home.bind(t));
    t.homeVod && x.post("/homeVod", t.home...
  });
}
let x = await e.db.get("/config/sites/list", []);
```

- 每个 spider 注册两组前缀：`/spider/<key>/<type>` 与 `/spider/<key>`，方法为 **POST**（`/init`、`/support`、`/home`、`/homeVod`…）。
- 与参考实现 `CatSpider.java` 一致：站点 `api` = `http://127.0.0.1:<port>/spider/<key>`，随后 `POST <api>/init|/home|/category|/detail|/search|/play`。
  → 本项目已实现的 `CatSpiderHTTPClient` 与之匹配（`api.contains("/spider/")` + POST JSON + `page` 为整数）。
- **站点清单入口**：bundle 内部使用 KV 键 `/config/sites/list`（同文件还有 `/settings/livetovod/url`、`/siteCookie/bili/cookie`、`/diy/emby/servers`）。
  → 站点列表的准确路由属 **M1.6 待实测项**，候选：`/config/sites/list`、`/sites/list`、`/spider/list`、`/config`。

## 四、宿主要提供的运行环境

| 项 | 要求 |
| --- | --- |
| 运行时 | 真 Node（**18.x**；bundle 使用 fastify 5 与 `node:` 前缀导入） |
| 环境变量 | `PORT`（宿主分配）、`HOST=127.0.0.1`、`NODE_ENV=production`；不要设 `CATVOD_DISABLE_AUTOSTART` |
| 工作目录 | 可写目录（bundle 使用 `fs` 写缓存） |
| argv[1] | 必须是 `.../index.js`（自启动条件依赖该后缀） |
| stdout/stderr | 必须采集：解析就绪行与端口、记录错误 |
| 网络 | 出站 HTTP/HTTPS（`net`/`tls`/`dns`） |
| 可选注入 | `globalThis.catDartServerPort()` + 宿主 `POST /msg` 端点（接收 `messageToDart` 通知） |

## 五、M1.6 PoC 验证清单（须在 macOS/真机完成）

1. **iOS 内嵌可行性**：nodejs-mobile **v18.20.4**（iPhone arm64 + 模拟器 arm64/x86_64）随包集成，`node::Start` 在独立后台线程启动；确认 `worker_threads`、`http2`、`dns`、`tls`、`zlib`、`fs` 在 iOS 沙盒内可用（不可用项需确认是否在关键路径）。
2. **体积**：libnode 带来的 ipa/app 体积增量（webhtv 注明 Android `.so` 约 60MB）。
3. **性能**：冷启动（下载 6.29MB + 执行 + 监听）、常驻内存、首屏搜索耗时（iOS 无 JIT，必须实测）。
4. **端口**：注入 `PORT`/`HOST`，解析就绪行取实际端口，覆盖 `EADDRINUSE` 自增场景。
5. **站点清单路由**：实测确定候选路由，确定 `sites[].api` 的实际形态。
6. **端到端**：`/init → /home → /category → /detail → /search → /play`（复用 `CatSpiderHTTPClient`）。
7. **macOS 路径**：随包 `node` 可执行文件（或自编译 libnode）+ `Process` 启动；记录 Gatekeeper 处理方式并写入分发文档。

## 六、更新流程（已实现）

`index.js` 与 `index.js.md5` 成对：先取 32 字节摘要 → 与本地缓存摘要比对 → 一致则直接执行缓存中的 `index.js`，不一致才重新下载 6.29MB。
实现：`CatVodCore/Config/ConfigLocator.swift`（`digestURL(for:)`、`needsDownload(remoteDigest:localDigest:)`）+ `MD5`（纯 Swift，RFC 1321，已用 RFC 向量与本次实测摘要覆盖）。

