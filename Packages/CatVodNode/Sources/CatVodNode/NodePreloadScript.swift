import Foundation

/// 内嵌 Node 的**预载脚本**（通过 ``NodeMobileLaunchPlan/preloadURL`` 注入 `-r`）。
///
/// 存在的理由来自一次真实失败：iOS 模拟器上跑真 bundle 时，测试进程在下载完成后
/// **13.5 秒凭空消失**（XCTest 只报 `Restarting after unexpected exit, crash, or test timeout`），
/// 没有任何断言输出 —— 因为 nodejs-mobile 是**进程内嵌**：
///
/// - bundle 里的致命错误（例如用到 iOS 版不提供的 `child_process`/`worker_threads`）
///   会让 node 调 `process.exit()`，而它退出就等于**宿主 App 退出**；
/// - 我们 `dup2` 抓到的 stdout 缓冲**随进程一起消失**，事后无从取证。
///
/// 因此预载做两件**只影响诊断、不改变 bundle 行为**的事：
///
/// 1. 把运行环境（版本、`argv`、`cwd`、关键 env、核心模块可用性）与致命错误
///    **逐行追加到 `YPLAYER_NODE_LOG`** —— 进程死了文件还在，这是唯一能带回来的证据；
/// 2. 拦截 `process.exit` / `uncaughtException` / `unhandledRejection`：记录堆栈并**保活**。
///    这样「宿主起不来」会变成界面上的「宿主未就绪 + 日志尾部」，而不是闪退。
///
/// 平台无关（只依赖 Foundation）：macOS 上也能单测脚本内容与写盘行为。
public enum NodePreloadScript {
    /// 落盘日志的路径通过这个环境变量告诉预载脚本。
    public static let logEnvironmentKey = "YPLAYER_NODE_LOG"
    /// 预载脚本文件名。
    public static let fileName = "yplayer-node-preload.js"
    /// 落盘日志文件名。
    public static let logFileName = "yplayer-node.log"

    /// 预载脚本源码。
    ///
    /// 刻意保持极简：只读环境、只写日志、只拦致命退出，**不碰** bundle 依赖的任何内部实现
    /// （预载一旦出错同样会带走宿主，所以它必须小到可以人工审阅）。
    public static let source = """
    /* YPlayer 内嵌 Node 预载脚本（由 NodeMobileLaunchPlan 以 -r 注入）。
     * 目的：把「内嵌 node 出错 → 宿主 App 直接死掉」变成「可回读的日志」。
     * 只做诊断，不改变 bundle 行为。 */
    (function () {
      'use strict';
      var fs = require('fs');
      var logPath = process.env.YPLAYER_NODE_LOG || '';

      function write(line) {
        var text = '[' + new Date().toISOString() + '] ' + line + '\\n';
        try { if (logPath) { fs.appendFileSync(logPath, text); } } catch (e) {}
        try { process.stderr.write('[YPlayer] ' + line + '\\n'); } catch (e) {}
      }

      function detail(error) {
        if (!error) { return String(error); }
        return error.stack ? String(error.stack) : String(error);
      }

      write('preload node=' + process.version + ' argv=' + JSON.stringify(process.argv));
      write('preload cwd=' + process.cwd());
      write('preload entry=' + (process.argv[1] || '<none>'));
      write('preload DEV_HTTP_PORT=' + process.env.DEV_HTTP_PORT
        + ' HOST=' + process.env.HOST);

      /* iOS 版 libnode 不提供全部核心模块（无 child_process / worker_threads）。
       * 逐个试加载并记录：这样「bundle 一起手就没有就绪行」时有第一手证据 —— 正是
       * docs/任务记录/M16P4-iOS内嵌libnode.md 里列的第 4 个未验证项。 */
      var names = ['child_process', 'worker_threads', 'cluster', 'vm', 'net', 'http', 'fs'];
      names.forEach(function (name) {
        try { require(name); write('preload module ok: ' + name); }
        catch (moduleError) {
          write('preload module MISSING: ' + name + ' -> ' + moduleError.message);
        }
      });

      process.on('uncaughtException', function (error) {
        write('FATAL uncaughtException: ' + detail(error));
      });
      process.on('unhandledRejection', function (reason) {
        write('FATAL unhandledRejection: ' + detail(reason));
      });

      process.exit = function (code) {
        write('BLOCKED process.exit(' + code + ') ' + detail(new Error('process.exit')));
        throw new Error('YPlayer blocked process.exit(' + code + ')');
      };

      write('preload ready (process.exit blocked)');
    })();
    """

    /// 预载脚本与落盘日志的暂存目录。
    ///
    /// 用临时目录而不是 App Bundle：真机上的 Bundle 不可写，而 node 需要能**读到**脚本本身
    /// （顺带验证「bundle 之外的路径 node 能不能读」，见实机验证清单第 5 项）。
    public static func stagingDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("yplayer-node", isDirectory: true)
    }

    /// 落盘日志路径（与 ``stagingDirectory(fileManager:)`` 同目录）。
    public static func logURL(fileManager: FileManager = .default) -> URL {
        stagingDirectory(fileManager: fileManager).appendingPathComponent(logFileName)
    }

    /// 把 ``source`` 写到暂存目录并返回路径。
    ///
    /// 幂等：内容一致就不重写（避免每次启动都动文件时间戳）。
    @discardableResult
    public static func materialize(fileManager: FileManager = .default) throws -> URL {
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let data = Data(source.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return url
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 读取落盘日志的尾部若干行（进程已消失时唯一可用的诊断来源）。
    public static func tail(lines: Int = 20, fileManager: FileManager = .default) -> [String] {
        guard lines > 0, let text = try? String(contentsOf: logURL(fileManager: fileManager), encoding: .utf8),
              !text.isEmpty
        else {
            return []
        }
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }
}
