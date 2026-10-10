import CommonCrypto
import Foundation

/// AES-128-CBC + PKCS7 —— HLS 的 `METHOD=AES-128` 就是这一套（RFC 8216 §4.3.2.4；M10k）。
///
/// 解密是下载链路要的（把密文片段还原成能播的字节）；`encrypt` 留给测试夹具造「加密片段」——
/// 夹具与实现用同一套参数，否则「解出来对不对」就没有验证意义。
///
/// 两种调用方各自把关：
/// - 密钥 / IV 长度不对、数据不是块长整数倍 → 给 nil，调用方**如实报错**，绝不把密文写进成品；
/// - 不抛错：失败在下载链路里已经有一层「带 episode 的可读原因」，这里只管算。
enum AES128CBC {
    /// 解密。
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        crypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    /// 加密（测试夹具用；与 ``decrypt(_:key:iv:)`` 严格对称）。
    static func encrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        crypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    private static func crypt(_ data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else {
            return nil
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            key.count,
                            ivBuffer.baseAddress,
                            dataBuffer.baseAddress,
                            data.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else {
            return nil
        }
        return output.prefix(moved)
    }
}
