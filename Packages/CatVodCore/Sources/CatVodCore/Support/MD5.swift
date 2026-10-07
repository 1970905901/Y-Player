import Foundation

/// 纯 Swift 的 MD5 实现（RFC 1321）。
///
/// 为什么自己实现：猫源接口用 `index.js.md5`（32 字节十六进制）做增量更新校验，
/// 而 `CatVodCore` 需要保持「仅 Foundation、可跨平台单测」，因此不使用 CommonCrypto / CryptoKit。
/// 依据：实测 `https://9280.kstore.vip/ceshi/index.js.md5` 返回 `35dcc10d533153dbb94298792664ad04`。
public enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    // K[i] = floor(abs(sin(i + 1)) * 2^32)
    private static let constants: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391
    ]

    /// 计算字节序列的 MD5，返回 32 位小写十六进制字符串。
    public static func hexDigest(of bytes: [UInt8]) -> String {
        hexDigest(of: Data(bytes))
    }

    /// 计算数据的 MD5，返回 32 位小写十六进制字符串。
    public static func hexDigest(of data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8

        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, through: 56, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset])
                    | (UInt32(message[offset + 1]) << 8)
                    | (UInt32(message[offset + 2]) << 16)
                    | (UInt32(message[offset + 3]) << 24)
            }

            var a = a0
            var b = b0
            var c = c0
            var d = d0

            for index in 0..<64 {
                let (f, g) = round(index, b: b, c: c, d: d)
                let rotated = a &+ f &+ constants[index] &+ words[g]
                let temp = d
                d = c
                c = b
                b = b &+ rotateLeft(rotated, by: shifts[index])
                a = temp
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        return [a0, b0, c0, d0].map(littleEndianHex).joined()
    }

    /// 计算文本（UTF-8）的 MD5。
    public static func hexDigest(of string: String) -> String {
        hexDigest(of: Data(string.utf8))
    }

    /// 校验 32 位十六进制摘要文本（大小写不敏感，允许首尾空白）。
    public static func matches(_ digest: String, _ expected: String) -> Bool {
        digest.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(expected.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func round(_ index: Int, b: UInt32, c: UInt32, d: UInt32) -> (UInt32, Int) {
        switch index {
        case 0..<16:
            ((b & c) | (~b & d), index)
        case 16..<32:
            ((d & b) | (~d & c), (5 * index + 1) % 16)
        case 32..<48:
            (b ^ c ^ d, (3 * index + 5) % 16)
        default:
            (c ^ (b | ~d), (7 * index) % 16)
        }
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func littleEndianHex(_ word: UInt32) -> String {
        let bytes = [
            UInt8(word & 0xff),
            UInt8((word >> 8) & 0xff),
            UInt8((word >> 16) & 0xff),
            UInt8((word >> 24) & 0xff)
        ]
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
