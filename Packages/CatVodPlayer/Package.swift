// swift-tools-version: 6.0
// CatVodPlayer：播放内核抽象 + MpvEngine(libmpv) + FFmpegEngine(自研)。
//
// 依赖引入节奏（刻意分阶段，保证 CI 每步可绿）：
//   M3：启用 MPVKit（LGPL 变体），同时提供 libmpv 与 Libav*（自研 FFmpegEngine 复用同一套二进制）。
//       启用方式：在 dependencies 中加入
//         .package(url: "https://github.com/mpvkit/MPVKit.git", exactVersion: "1.0.0")
//       并在 target dependencies 中加入 "MPVKit"，随后更新 ThirdParty/mpvkit.lock.json。
//   M4：自研 FFmpegEngine 直接使用 MPVKit 提供的 Libav* / Libass，不引入第二套 FFmpeg。
//
// 在 MPVKit 启用之前，MpvEngine 相关实现以 #if canImport(Libmpv) 隔离，
// 运行时通过 PlayerEngineKind 的可用性探测报告 .unsupported，而不是编译失败。
//
// 语言模式：本包与 C API（libmpv/FFmpeg）交互密集，先用 Swift 5 模式，
// 待接口稳定后再迁移到 Swift 6 模式（见 docs/任务记录 中的迁移任务）。
import PackageDescription

let package = Package(
    name: "CatVodPlayer",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodPlayer", targets: ["CatVodPlayer"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        .package(path: "../CatVodNet"),
    ],
    targets: [
        .target(
            name: "CatVodPlayer",
            dependencies: ["CatVodCore", "CatVodNet"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CatVodPlayerTests",
            dependencies: ["CatVodPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
