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
    /// 打印进度并立刻刷出（不要改成 print 了事：进程可能下一秒就没了）。
    static func step(_ text: String) {
        print("YPLAYER-PROBE: \(text)")
        fflush(stdout)
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
