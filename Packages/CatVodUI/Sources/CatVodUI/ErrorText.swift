import CatVodCore
import Foundation

/// 统一把错误转换成给用户看的文本。
///
/// `CatVodError` 自带可读描述（含站点 key、状态码、原因），优先使用；其它错误回落到系统描述。
func userFacingMessage(_ error: Error) -> String {
    (error as? CatVodError)?.errorDescription ?? error.localizedDescription
}
