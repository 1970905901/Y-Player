import CatVodSource
import Foundation
import XCTest

/// 内嵌 Node 探针的公共材料。
///
/// 一次真实失败（模拟器上测试进程在下载完成后 13.5 秒凭空消失，只留下
/// `Restarting after unexpected exit, crash, or test timeout`）说明了两件事，
/// 这里都做了处理：
///
/// 1. **要有进度**：内嵌 node 崩了会把宿主进程一起带走，没刷出去的缓冲全都丢，
///    所以每一步都 `print` 后立刻 `fflush`（CI 日志里就能看出死在哪一步）；
/// 2. **要有两层**：能精确复现契约的最小 bundle 放在主线（确定性、无网络），
///    真 bundle 另设开关（见 `RealBundleHostProbeTests`），出问题不拖垮主线。
enum NodeProbeSupport {
    /// 探针步骤的落盘文件（**唯一可靠的通道**）。
    ///
    /// 实测结论（2026-10-07 第二轮 CI，`simulator` 运行 `37632710891`）：
    /// 宿主启动时把 fd 1 与 fd 2 **一起** `dup2` 到采集管道（``NodeMobileRuntime`` 的就绪行
    /// 解析依赖它），于是**那之后的步骤用 `print` 和 `NSLog` 都进不了 CI 日志** ——
    /// `NSLog` 在 Apple 平台写的是 stderr，一样被重定向吃掉。
    /// 证据：日志里 `host starting`（启动前）两种形态都在，而 `host ready`（启动后）一条都没有。
    ///
    /// 所以可靠做法是**写文件**，并在 ``dumpProbeLog()`` 里于 `stop()`（fd 已还原）之后读出来 ——
    /// 这样成功路径也能在 CI 里看到完整步骤序列；失败路径本来就会把日志尾部附进错误信息。
    static var probeLogURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yplayer-probe.log")
    }

    /// 记录一步：本地输出 + 落盘（落盘的是**唯一**能在 CI 里活下来的那份）。
    static func step(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("YPLAYER-PROBE: \(text)")
        fflush(stdout)
        // 保留 NSLog：它证伪了「NSLog 能穿过重定向」，也是本地调试时最方便的一路。
        NSLog("YPLAYER-PROBE: %@", text)
        append("\(stamp) YPLAYER-PROBE: \(text)\n")
    }

    /// 落盘探针日志的文本（失败时拼进错误信息用）。
    static func probeLogText() -> String {
        (try? String(contentsOf: probeLogURL, encoding: .utf8)) ?? ""
    }

    /// 把落盘的探针日志整段打出来。**必须在 `service.stop()` 之后调用**（那时 fd 已还原）。
    static func dumpProbeLog() {
        let text = probeLogText()
        guard !text.isEmpty else {
            print("--- 探针日志：无（预载或 step 未生效）---")
            fflush(stdout)
            return
        }
        print("--- 探针日志（落盘，按时间顺序）---\n\(text)--- 探针日志结束 ---")
        fflush(stdout)
    }

    private static func append(_ line: String) {
        let url = probeLogURL
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// 落盘日志尾部（进程消失后唯一还能读到的现场）。
    static func logTail(of service: JS2PHostService, lines: Int = 30) async -> [String] {
        guard let url = await service.hostLogPath(),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty
        else {
            return ["<无落盘日志：预载可能未生效，见 NodePreloadScript>"]
        }
        return Array(text.split(whereSeparator: \.isNewline).map(String.init).suffix(lines))
    }
}

/// 最小 bundle：复刻契约里**能被验证的那部分形状**，不含任何网络或第三方依赖。
///
/// 它必须在文件名、env 读取方式、就绪行文案上与真 bundle 一致 ——
/// 否则测的就不是我们的宿主链路了。相对 `api`（`/spider/probe/3`）也是刻意的：
/// 补全逻辑必须被覆盖，否则真机上站点会指向一个不存在的地址。
enum MiniBundleScript {
    static let fileName = "index.js"

    static let source = """
    'use strict';
    var http = require('http');
    var host = process.env.HOST || '127.0.0.1';
    var preferred = Number(process.env.DEV_HTTP_PORT || 9988);
    var catalog = {
      video: {
        sites: [
          { key: 'nodejs_probe', name: '探针|首页', type: 3, api: '/spider/probe/3',
            indexs: 1, enable: true, searchable: 1, quickSearch: 1 }
        ]
      }
    };
    var server = http.createServer(function (request, response) {
      response.setHeader('content-type', 'application/json; charset=utf-8');
      if (request.url === '/health') {
        response.end(JSON.stringify({ ok: true, name: 'CatVodSpiderios' }));
        return;
      }
      if (request.url === '/full-config' || request.url === '/config') {
        response.end(JSON.stringify(catalog));
        return;
      }
      response.statusCode = 404;
      response.end('{}');
    });
    server.listen(preferred, host, function () {
      var line = 'CatVodSpiderios listening on http://' + host + ':' + server.address().port;
      console.log(line);
    });
    """

    /// 写到**临时目录**而不是 App Bundle：真机上 Bundle 不可写，
    /// 而宿主必须能读到容器里的脚本（对应实机验证清单第 5 项）。
    static func materialize(fileManager: FileManager = .default) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("yplayer-mini-bundle", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(source.utf8).write(to: url, options: .atomic)
        return url
    }
}

/// 真 bundle 的准备：下载 6.29 MB 的 `index.js`（文件名本身是自启动条件的一部分）。
enum RealBundleFixture {
    static let remoteURL = "https://9280.kstore.vip/ceshi/index.js"

    static func localIndexJS() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("js2p", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("index.js")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        guard let url = URL(string: remoteURL) else {
            throw XCTSkip("bundle 地址无法解析")
        }
        do {
            NodeProbeSupport.step("downloading bundle")
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, data.count > 1_000_000 else {
                throw XCTSkip("bundle 下载异常：status=\(status) bytes=\(data.count)")
            }
            try data.write(to: target, options: .atomic)
            NodeProbeSupport.step("bundle downloaded: \(data.count) bytes")
            return target
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("bundle 不可达（\(error.localizedDescription)）—— 环境问题，跳过而非判失败")
        }
    }
}
