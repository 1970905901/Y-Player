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
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    // K[i] = floor(abs(sin(i + 1)) * 2^32)
    private static let constants: [UInt32] = [
        0xD76A_A478, 0xE8C7_B756, 0x2420_70DB, 0xC1BD_CEEE,
        0xF57C_0FAF, 0x4787_C62A, 0xA830_4613, 0xFD46_9501,
        0x6980_98D8, 0x8B44_F7AF, 0xFFFF_5BB1, 0x895C_D7BE,
        0x6B90_1122, 0xFD98_7193, 0xA679_438E, 0x49B4_0821,
        0xF61E_2562, 0xC040_B340, 0x265E_5A51, 0xE9B6_C7AA,
        0xD62F_105D, 0x0244_1453, 0xD8A1_E681, 0xE7D3_FBC8,
        0x21E1_CDE6, 0xC337_07D6, 0xF4D5_0D87, 0x455A_14ED,
        0xA9E3_E905, 0xFCEF_A3F8, 0x676F_02D9, 0x8D2A_4C8A,
        0xFFFA_3942, 0x8771_F681, 0x6D9D_6122, 0xFDE5_380C,
        0xA4BE_EA44, 0x4BDE_CFA9, 0xF6BB_4B60, 0xBEBF_BC70,
        0x289B_7EC6, 0xEAA1_27FA, 0xD4EF_3085, 0x0488_1D05,
        0xD9D4_D039, 0xE6DB_99E5, 0x1FA2_7CF8, 0xC4AC_5665,
        0xF429_2244, 0x432A_FF97, 0xAB94_23A7, 0xFC93_A039,
        0x655B_59C3, 0x8F0C_CC92, 0xFFEF_F47D, 0x8584_5DD1,
        0x6FA8_7E4F, 0xFE2C_E6E0, 0xA301_4314, 0x4E08_11A1,
        0xF753_7E82, 0xBD3A_F235, 0x2AD7_D2BB, 0xEB86_D391,
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
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xEFCD_AB89
        var c0: UInt32 = 0x98BA_DCFE
        var d0: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0 ..< 16 {
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

            for index in 0 ..< 64 {
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
        case 0 ..< 16:
            ((b & c) | (~b & d), index)
        case 16 ..< 32:
            ((d & b) | (~d & c), (5 * index + 1) % 16)
        case 32 ..< 48:
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
            UInt8(word & 0xFF),
            UInt8((word >> 8) & 0xFF),
            UInt8((word >> 16) & 0xFF),
            UInt8((word >> 24) & 0xFF),
        ]
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
