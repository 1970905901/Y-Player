import CatVodCore
import FlyingFox
import FlyingSocks
import Foundation

/// `/proxy` 落盘文件的暂存处（M06b 的流式转发；M06p 加配额与「在用登记」）。
///
/// 为什么需要它：媒体文件可能几十 GB，缓冲转发会撞 ``LocalProxyUpstreamClient/maximumBodyBytes``；
/// 响应体先落盘、再由本机服务流给播放器。
///
/// 三件事（M06b → M06p 的演进）：
/// 1. **暂存目录**：`<系统临时目录>/YPlayerProxy`，一次请求一个 UUID 文件；
/// 2. **清扫**（`sweep`）：每次新请求顺手清一遍 —— 超过 ``maximumAge``（15 分钟）的陈年残渣清掉；
///    总量超过 ``maximumBytes``（配额）时按「最旧先清」补到配额以内；
/// 3. **在用登记**（M06p）：正在写 / 正在发的文件**永不清**（``markInUse(_:)`` / ``releaseInUse(_:)``）——
///    没有它，边下边发（M06p）的文件会在传输途中被清扫扫掉。
///
/// 登记过的文件其实**发完即删**（``LocalProxyFileBuffer`` 释放时删），宽限期是给
/// 「没登记就躺在那儿」的残渣留的兜底（崩溃、上一进程的遗留）。
public enum LocalProxyTempFiles {
    /// 宽限期：兜底用的「陈年残渣」判定（登记过的文件不受它管，发完即删）。
    public static let maximumAge: TimeInterval = 15 * 60

    /// 总量配额（默认 1 GiB）：超过就按「最旧先清」淘汰**不在用**的文件。
    ///
    /// 为什么宽限期之外还要配额：宽限期只治「老」，治不了「一堆新鲜但已经没人要的」——
    /// 比如崩溃前刚落下的一批、或者客户端反复请求整份大文件（每个请求一份新文件）。
    /// 淘汰只动不在用的：**单个大文件自己超过配额也照发**（宁可超，也不删正在放的东西）。
    public static let maximumBytes: Int64 = 1 << 30

    /// 一次清扫的结果（测试与排障用；正常路径不关心）。
    public struct SweepReport: Sendable, Equatable {
        /// 清掉的文件数与被清掉的字节数。
        public var removedFiles = 0
        public var removedBytes: Int64 = 0
        /// 因为有请求在用而跳过（不删）的文件数。
        public var keptInUse = 0
        /// 清完之后目录里的总字节数（含在用的 —— 它们也得算占用）。
        public var totalBytes: Int64 = 0

        public init() { }
    }

    /// 暂存目录：`<系统临时目录>/YPlayerProxy`。
    public static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("YPlayerProxy", isDirectory: true)
    }

    /// 造一个新的暂存文件地址（目录不存在就建；**只给地址，不建文件**）。
    public static func makeFileURL() throws -> URL {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".tmp", isDirectory: false)
    }

    // MARK: - 在用登记（M06p）

    /// 登记「这个文件有请求在用」（正在写 / 正在发）：清扫不会碰它。
    public static func markInUse(_ fileURL: URL) {
        inUse.mark(fileURL)
    }

    /// 注销（幂等）：``LocalProxyFileBuffer`` 释放时调，之后这个文件可以被清扫回收。
    public static func releaseInUse(_ fileURL: URL) {
        inUse.release(fileURL)
    }

    /// 当前在用文件数（测试与排障用）。
    public static var inUseCount: Int {
        inUse.count
    }

    // MARK: - 清扫（宽限期 + 配额）

    /// 清扫一遍：列出目录 → 交给纯策略 ``plan(entries:now:maximumAge:quota:)`` 判该删谁 → 删。
    /// **在用的一律不动**（它们要么正在写、要么正在发给播放器，删了就是断流）。
    ///
    /// - Parameters:
    ///   - now: 「现在」（测试注入用）。
    ///   - quota: 总量上限（默认 ``maximumBytes``；测试注入小值用）。
    @discardableResult
    public static func sweep(now: Date = Date(), quota: Int64 = maximumBytes) -> SweepReport {
        let entries = listEntries()
        let doomed = Set(plan(entries: entries, now: now, quota: quota))
        var report = SweepReport()
        report.keptInUse = entries.filter(\.inUse).count
        report.totalBytes = entries.reduce(0) { $0 + $1.size }
        for entry in entries where doomed.contains(entry.url) {
            guard remove(entry.url) else { continue }
            report.removedFiles += 1
            report.removedBytes += entry.size
            report.totalBytes -= entry.size
        }
        return report
    }

    /// 清扫策略（**纯逻辑**，有单测）：给一批文件与「现在 / 宽限期 / 配额」，吐该删哪些。
    ///
    /// 两条规则按顺序：
    /// 1. **宽限期**：修改时间超过 `maximumAge` 的（没人登记的陈年残渣）；
    /// 2. **配额**：总量（含在用的）超过 `quota` 时，把**不在用**的按最旧先清，直到回到线内。
    ///
    /// 在用的（`inUse == true`）**永远不进结果** —— 单个大文件自己超过配额也照发（宁可超，
    /// 也不删正在放的东西）；清不掉的部分留给下一次清扫。
    static func plan(
        entries: [LocalProxySweepEntry],
        now: Date,
        maximumAge: TimeInterval = LocalProxyTempFiles.maximumAge,
        quota: Int64 = LocalProxyTempFiles.maximumBytes
    ) -> [URL] {
        var doomed: [URL] = []
        var idle: [LocalProxySweepEntry] = []
        var total: Int64 = 0
        for entry in entries {
            total += entry.size
            guard !entry.inUse else { continue }
            if now.timeIntervalSince(entry.modified) > maximumAge {
                doomed.append(entry.url)
            } else {
                idle.append(entry)
            }
        }
        guard total > quota else {
            return doomed
        }
        for entry in idle.sorted(by: { $0.modified < $1.modified }) {
            guard total > quota else { break }
            doomed.append(entry.url)
            total -= entry.size
        }
        return doomed
    }

    /// 目录里现存的暂存文件（拿不到目录就是空的）。
    private static func listEntries() -> [LocalProxySweepEntry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory(),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            return LocalProxySweepEntry(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date(),
                inUse: inUse.contains(url)
            )
        }
    }

    /// 删一个；删不掉回 false（如实留着，下次再清）。
    private static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static let inUse = LocalProxyTempFileRegistry()
}

/// 清扫时看到的一个文件（``LocalProxyTempFiles/plan(entries:now:maximumAge:quota:)`` 的输入：
/// 把「目录里有什么」与「谁在用」抽出来，策略本身就能纯逻辑单测）。
struct LocalProxySweepEntry: Sendable, Equatable {
    var url: URL
    var size: Int64
    var modified: Date
    var inUse: Bool
}

/// 「在用文件」的登记本（静态可变状态在 Swift 6 下收进类型，别裸放全局）。
///
/// 用 `path` 字符串当键：`URL` 的 `==` 会做规范化（大小写、`.` 段），同一份文件
/// 用不同写法构造出来的两个 `URL` 必须落到同一个键上。
private final class LocalProxyTempFileRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func mark(_ url: URL) {
        lock.lock()
        paths.insert(url.path)
        lock.unlock()
    }

    func release(_ url: URL) {
        lock.lock()
        paths.remove(url.path)
        lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(url.path)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

/// 「边写边读」的落盘缓冲（M06p 的边下边发）：生产者（`HTTPStreamingTransport` 的块）
/// 一块块写进来，FlyingFox 的响应体（``LocalProxyFileSequence``）在另一头读**同一份文件** ——
/// 写到哪读到哪，播放器不用等整份下完。
///
/// 生命周期（这是 M06b 缺的那块拼图）：
/// - ``init(fileURL:)`` 建文件并登记「在用」——清扫不会碰它；
/// - 响应体发完 / 客户端断开 / 响应被丢弃 ⇒ 引用归零 ⇒ `deinit` 注销登记并**删文件**。
///   也就是说：文件最多活到「没人再需要它」那一刻，不再靠 15 分钟宽限期兜底。
///
/// 长度口径：上游 `Content-Length` 有 → 响应体带 `Content-Length` 发；没有 → 交掉 chunked
/// （FlyingFox 见到 `count == nil` 会自动加 `Transfer-Encoding: chunked`）。
/// 上游提前收尾（写不够期望长度）时读侧会抛错 —— 让连接断掉，别把短的实体留在 keep-alive 流里。
public final class LocalProxyFileBuffer: @unchecked Sendable {
    /// 落盘文件（清扫与测试都要看它）。
    public let fileURL: URL

    private let lock = NSLock()
    private var writer: FileHandle?
    private var written = 0
    private var expected: Int?
    private var state: State = .writing
    private var waiter: CheckedContinuation<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var pumpCancel: (@Sendable () -> Void)?

    /// 写侧状态。`.failed` 的 error 会被读侧抛出去（连接随之断掉，客户端看到的是「断了」而不是「悄悄短一截」）。
    enum State {
        case writing
        case finished
        case failed(any Error)
    }

    /// 读侧能看到的错误。
    enum BufferError: LocalizedError {
        /// 上游提前收尾：实收字节数与期望长度对不上。
        case truncated(expected: Int, received: Int)
        /// 落盘文件读不出来（被外面删了 / 权限坏了）。
        case unreadable

        var errorDescription: String? {
            switch self {
            case let .truncated(expected, received):
                "落盘缓冲和 Content-Length 对不上：写了 \(received)/\(expected) 字节（上游提前收尾）"
            case .unreadable:
                "落盘缓冲读不出来"
            }
        }
    }

    /// 建缓冲：建文件 + 开写句柄 + 登记「在用」。
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: fileURL)
        else {
            throw CatVodError.localServer(reason: "落盘文件建不出来：\(fileURL.lastPathComponent)")
        }
        writer = handle
        LocalProxyTempFiles.markInUse(fileURL)
    }

    deinit {
        pumpCancel?()
        pumpTask?.cancel()
        lock.lock()
        try? writer?.close()
        writer = nil
        lock.unlock()
        LocalProxyTempFiles.releaseInUse(fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 期望总长度（上游 `Content-Length`）；nil = 不知道长度（给客户端时走 chunked）。
    public var expectedBytes: Int? {
        locked { expected }
    }

    /// 已写入的字节数。
    public var writtenBytes: Int {
        locked { written }
    }

    /// 接上一个流式响应（M06p 的主路径）：后台把 `chunks` 一块块写进文件，
    /// 读完 `finish()`、中途出错 `fail(_:)`。期望长度从响应头里读。
    func attach(_ stream: HTTPStream) {
        lock.lock()
        expected = Self.contentLength(stream.headers)
        pumpCancel = stream.cancel
        lock.unlock()
        let task = Task { [weak self] in
            do {
                for try await chunk in stream.chunks {
                    guard let self else { return }
                    try append(chunk)
                }
                self?.finish()
            } catch {
                self?.fail(error)
            }
        }
        lock.lock()
        pumpTask = task
        lock.unlock()
    }

    /// 整份已经在文件里了（不支持流式的传输实现走这条路，M06b 的落盘转发）：
    /// 认领字节数，当「写完」。文件是别人写的，先把我们的写句柄让开。
    func adoptExistingFile(byteCount: Int) {
        lock.lock()
        try? writer?.close()
        writer = nil
        written = byteCount
        expected = byteCount
        state = .finished
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    /// 丢弃：撤下载、注销、删文件（非 2xx、或上游抛错时由处理器调用）。
    public func discard() {
        pumpCancel?()
        pumpTask?.cancel()
        lock.lock()
        try? writer?.close()
        writer = nil
        state = .finished
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
        LocalProxyTempFiles.releaseInUse(fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 交给 FlyingFox 的响应体：知道长度就带 `Content-Length`，不知道就 chunked。
    func makeBody() -> HTTPBodySequence {
        let sequence = LocalProxyFileSequence(buffer: self)
        guard let expected else {
            return HTTPBodySequence(from: sequence)
        }
        return HTTPBodySequence(from: sequence, count: expected)
    }

    // MARK: - 写侧（生产者）

    /// 写一块。超过期望长度的部分直接丢掉 —— 响应体多写一个字节就会污染 keep-alive 的下一条响应。
    func append(_ data: Data) throws {
        lock.lock()
        guard case .writing = state else {
            lock.unlock()
            return
        }
        var payload = data
        if let expected, written + payload.count > expected {
            payload = payload.prefix(Swift.max(expected - written, 0))
        }
        if !payload.isEmpty {
            do {
                try writer?.write(contentsOf: payload)
            } catch {
                state = .failed(error)
                let pending = waiter
                waiter = nil
                lock.unlock()
                pending?.resume()
                throw error
            }
            written += payload.count
        }
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    /// 写完了（上游正常收尾）。
    func finish() {
        lock.lock()
        if case .writing = state {
            state = .finished
        }
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    /// 中途坏了（读侧会把这个错抛出去，连接随之断掉）。
    func fail(_ error: any Error) {
        lock.lock()
        if case .writing = state {
            state = .failed(error)
        }
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    // MARK: - 读侧（响应体）

    /// 一眼当前的「可读上界 + 状态」（读侧循环用）。
    func snapshot() -> (available: Int, state: State) {
        lock.lock()
        defer { lock.unlock() }
        return (written, state)
    }

    /// 等到「可读字节超过 `offset`」或「写侧结束」（写完 / 坏了）——**单消费者**：
    /// 同一时刻只有一个等待者（响应体只有一条读链），多一个会把先来的那个忘掉。
    ///
    /// 锁在同步小方法 ``installWaiter(_:beyond:)`` 里加 —— `async` 函数体里不能直接
    /// `lock()/unlock()`（Swift 6 里 NSLock 这对方法在异步上下文**不可用**，M03P11 踩过同一坑）。
    func waitForData(beyond offset: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            installWaiter(continuation, beyond: offset)
        }
    }

    /// **同步**：该等就把等待者装上；不该等（已有新数据 / 写侧已结束）当场放行。
    private func installWaiter(_ continuation: CheckedContinuation<Void, Never>, beyond offset: Int) {
        lock.lock()
        guard written <= offset, case .writing = state else {
            lock.unlock()
            continuation.resume()
            return
        }
        waiter = continuation
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 响应头里能不能信 `Content-Length`（大小写不敏感；返回 nil = 发 chunked）。
    ///
    /// **带了 `Content-Encoding`（gzip 等）就不能信**：实体已经被 URLSession 解压，
    /// 头里那个长度说的是压缩后的大小 —— 按它封顶会把实体截短。
    static func contentLength(_ headers: [String: String]) -> Int? {
        for (key, value) in headers where key.lowercased() == "content-encoding" {
            let encoding = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard encoding.isEmpty || encoding == "identity" else {
                return nil
            }
        }
        for (key, value) in headers where key.lowercased() == "content-length" {
            return Int(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// ``LocalProxyFileBuffer`` 的**读侧**：把增长中的文件当字节序列吐给 FlyingFox 的响应体。
///
/// 读的粒度：`nextBuffer(suggested:)` 一次读到「当前可读上界」（可能比请求的少 —— 上游还没写那么多），
/// 读空了就等（``LocalProxyFileBuffer/waitForData(beyond:)``），而不是返回 nil 收尾 ——
/// 「还没写完」和「写完了」是两件事（后者才是序列结束）。
///
/// 收尾口径：写到期望长度就结束；上游提前收尾（不够长）则抛 ``LocalProxyFileBuffer/BufferError/truncated(expected:received:)`` ——
/// 让连接断掉，别把短实体留在 keep-alive 流里（下一条响应会被错位解析）。
struct LocalProxyFileSequence: AsyncBufferedSequence {
    typealias Element = UInt8

    let buffer: LocalProxyFileBuffer

    func makeAsyncIterator() -> Iterator {
        Iterator(buffer: buffer)
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Buffer = Data

        let buffer: LocalProxyFileBuffer
        private var handle: FileHandle?
        private var offset = 0

        init(buffer: LocalProxyFileBuffer) {
            self.buffer = buffer
        }

        mutating func next() async throws -> UInt8? {
            try await nextBuffer(suggested: 1)?.first
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            while true {
                try Task.checkCancellation()
                let snapshot = buffer.snapshot()
                if offset < snapshot.available {
                    let want = Swift.min(Swift.max(count, 1), snapshot.available - offset)
                    guard let data = try read(upTo: want), !data.isEmpty else {
                        throw LocalProxyFileBuffer.BufferError.unreadable
                    }
                    offset += data.count
                    return data
                }
                if let expected = buffer.expectedBytes, offset >= expected {
                    return nil
                }
                switch snapshot.state {
                case .writing:
                    await buffer.waitForData(beyond: offset)
                case .finished:
                    if let expected = buffer.expectedBytes, offset < expected {
                        throw LocalProxyFileBuffer.BufferError.truncated(expected: expected, received: offset)
                    }
                    return nil
                case let .failed(error):
                    throw error
                }
            }
        }

        /// 顺序读（开一次句柄，之后读位置自己往前走）。
        private mutating func read(upTo count: Int) throws -> Data? {
            if handle == nil {
                handle = try FileHandle(forReadingFrom: buffer.fileURL)
            }
            return try handle?.read(upToCount: count)
        }
    }
}
