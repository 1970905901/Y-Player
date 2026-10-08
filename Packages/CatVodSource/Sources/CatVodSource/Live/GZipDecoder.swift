import Foundation

#if canImport(Compression)
import Compression
#endif

/// gzip 解压：直播源的节目单常以 `.xml.gz` 提供（上游用 Java 的 `GZIPInputStream`）。
///
/// 为什么自己写：Foundation 没有 gzip API，iOS 上也起不了外部进程；
/// 系统自带的 `Compression` 只做**裸 DEFLATE**（不是 gzip 容器），所以这里按 RFC 1952
/// 手工跳过 gzip 头尾：
/// `1f 8b` 魔数 + `CM=08` + `FLG` → 10 字节固定头 → 按 `FLG` 跳过
/// `FEXTRA`/`FNAME`/`FCOMMENT`/`FHCRC` → DEFLATE 数据 → 8 字节尾（CRC32 + ISIZE）。
///
/// 失败返回 `nil`：调用方必须**明确报错**（`CatVodError.parseFailed`），不静默当成空节目单。
public enum GZipDecoder {
    /// 是不是 gzip：按魔数判断，不信地址里的扩展名（很多站点的下载地址是 `?gz=1` 这种形态）。
    public static func looksLikeGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// 解压 gzip 数据；不是 gzip、头尾不完整、DEFLATE 出错都返回 `nil`。
    public static func decode(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard let payload = deflatePayload(data) else {
            return nil
        }
        return inflate(payload)
        #else
        return nil
        #endif
    }

    #if canImport(Compression)
    /// 跳过 gzip 头与 8 字节尾，取出 DEFLATE 数据。
    private static func deflatePayload(_ data: Data) -> Data? {
        // 10 字节头 + 至少 1 字节数据 + 8 字节尾。
        guard data.count > 18 else {
            return nil
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            return nil
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else {
                return nil
            }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        if flags & 0x08 != 0 { // FNAME
            offset = skippingZeroTerminated(bytes, from: offset)
        }
        if flags & 0x10 != 0 { // FCOMMENT
            offset = skippingZeroTerminated(bytes, from: offset)
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset + 8 <= bytes.count else {
            return nil
        }
        return data.subdata(in: offset ..< (bytes.count - 8))
    }

    /// 跳过以 `0` 结尾的字符串字段（`FNAME`/`FCOMMENT`），返回它之后的下标。
    private static func skippingZeroTerminated(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        return index + 1
    }

    /// 裸 DEFLATE 解压（`COMPRESSION_ZLIB` 在 Apple 的 `Compression` 里指 raw deflate，不是 zlib 容器）。
    private static func inflate(_ payload: Data) -> Data? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            stream.deallocate()
            return nil
        }
        defer {
            compression_stream_destroy(stream)
            stream.deallocate()
        }

        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var source = [UInt8](payload)
        var output = Data()
        var failed = false
        source.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress else {
                failed = true
                return
            }
            stream.pointee.src_ptr = UnsafePointer(base)
            stream.pointee.src_size = bytes.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = capacity
                // 一次把输入喂完并带上 FINALIZE：gzip 数据到这儿已经没有后续输入。
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    failed = true
                    return
                }
                output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: capacity - stream.pointee.dst_size))
            } while status == COMPRESSION_STATUS_OK && stream.pointee.src_size > 0
        }
        return failed ? nil : output
    }
    #endif
}
