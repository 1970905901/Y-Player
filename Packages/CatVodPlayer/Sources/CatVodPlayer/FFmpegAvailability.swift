#if canImport(Libavcodec)
import Libavcodec
#endif
#if canImport(Libavformat)
import Libavformat
#endif
#if canImport(Libavutil)
import Libavutil
#endif
#if canImport(Libswscale)
import Libswscale
#endif
#if canImport(Libswresample)
import Libswresample
#endif
#if canImport(Libass)
import Libass
#endif

/// 自研 `FFmpegEngine`（M4）的**依赖底座事实**。
///
/// 与 ``MpvAvailability`` 同一套路，只是对象换成 Libav*：MPVKit 声称同时提供 libmpv 与 FFmpeg，
/// 而 M4 的自研内核**必须**直接调 Libav* —— 「声称」不算数，能不能 `import`、能不能链接、
/// 版本号是多少，全部在这里变成可断言的事实（`FFmpegAvailabilityTests`）。
///
/// 两层事实刻意分开（与 MPV 那边同一条纪律，别混用）：
/// - **依赖事实**：六个模块的 import 结论 + 运行期版本号（``probes``）；
/// - **实装事实**：``isEngineImplemented`` —— 引擎没实装前 `.ffmpeg` 始终「不可用」，
///   哪怕依赖全齐（「能链接上」不等于「播得了」）。
///
/// 只探**引擎真会用的**六个模块：demux（Libavformat）、解码（Libavcodec）、基础（Libavutil）、
/// 软解路径的像素 / 采样转换（Libswscale / Libswresample）、字幕（Libass）。
/// Libavfilter / Libavdevice 引擎不用，不探 —— 探针也得有人消费。
public enum FFmpegAvailability {
    /// 一个模块的探针结果。
    public struct Probe: Sendable, Equatable {
        /// 模块名（`import` 与诊断展示用同一份名字）。
        public let name: String
        /// 编译期能不能 `import`。
        public let available: Bool
        /// 运行期读到的版本号（`major.minor.micro`；模块不可用或读不到为 nil）。
        public let version: String?
    }

    /// 六个模块的探针（顺序 = 诊断里的显示顺序）。
    public static var probes: [Probe] {
        [libavcodec, libavformat, libavutil, libswscale, libswresample, libass]
    }

    /// 可用的模块数。
    public static var availableCount: Int {
        probes.filter(\.available).count
    }

    /// 缺的模块名（空数组 = 依赖齐）。
    public static var missingNames: [String] {
        probes.filter { !$0.available }.map(\.name)
    }

    /// 六个模块是否都可用。
    public static var isComplete: Bool {
        missingNames.isEmpty
    }

    /// 自研 `FFmpegEngine` 是否已实装（M4 进行中 → false）。
    ///
    /// **依赖就绪 ≠ 能用**：就算上面全绿，也要等引擎接进 ``PlayerCoordinator`` 的创建路径
    /// （与 MPV 的 ``MpvAvailability/isVideoOutputReady`` 同一条纪律）才能翻 true。
    public static let isEngineImplemented = false

    /// 供界面 / 日志展示的一行说明（诊断报告直接用）。
    public static var summary: String {
        let parts = probes.map { probe -> String in
            if probe.available {
                return "\(probe.name)=\(probe.version ?? "可用")"
            }
            return "\(probe.name)=缺"
        }
        let engine = isEngineImplemented ? "引擎已实装" : "引擎未实装"
        return "Libav \(availableCount)/\(probes.count)：\(parts.joined(separator: "，"))；\(engine)"
    }

    /// FFmpeg 版本号的写法（`AV_VERSION_INT`）：`major << 16 | minor << 8 | micro`。
    ///
    /// 单独拉出来是为了能**跨平台单测**：没有 Libav 的机器也能验格式化逻辑。
    public static func versionText(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFF
        let minor = (raw >> 8) & 0xFF
        let micro = raw & 0xFF
        return "\(major).\(minor).\(micro)"
    }

    // MARK: - 逐个模块（每个模块一个探针，`#if` 只出现在这里）

    private static var libavcodec: Probe {
        #if canImport(Libavcodec)
        return Probe(name: "Libavcodec", available: true, version: versionText(UInt32(avcodec_version())))
        #else
        return Probe(name: "Libavcodec", available: false, version: nil)
        #endif
    }

    private static var libavformat: Probe {
        #if canImport(Libavformat)
        return Probe(name: "Libavformat", available: true, version: versionText(UInt32(avformat_version())))
        #else
        return Probe(name: "Libavformat", available: false, version: nil)
        #endif
    }

    private static var libavutil: Probe {
        #if canImport(Libavutil)
        return Probe(name: "Libavutil", available: true, version: versionText(UInt32(avutil_version())))
        #else
        return Probe(name: "Libavutil", available: false, version: nil)
        #endif
    }

    private static var libswscale: Probe {
        #if canImport(Libswscale)
        return Probe(name: "Libswscale", available: true, version: versionText(UInt32(swscale_version())))
        #else
        return Probe(name: "Libswscale", available: false, version: nil)
        #endif
    }

    private static var libswresample: Probe {
        #if canImport(Libswresample)
        return Probe(name: "Libswresample", available: true, version: versionText(UInt32(swresample_version())))
        #else
        return Probe(name: "Libswresample", available: false, version: nil)
        #endif
    }

    private static var libass: Probe {
        #if canImport(Libass)
        // 版本号编码没核实过（不猜），先只报可用性。
        return Probe(name: "Libass", available: true, version: nil)
        #else
        return Probe(name: "Libass", available: false, version: nil)
        #endif
    }
}
