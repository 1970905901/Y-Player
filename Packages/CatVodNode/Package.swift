// swift-tools-version: 6.0
// CatVodNode：内嵌 Node 运行时的宿主适配（M1.6）。
//
// 契约来源：`docs/js2p宿主契约.md`（对 6.29 MB 的 index.js 逐字实测）。
// 只依赖 Foundation；不引入任何第三方包。
//
// 语言模式：Swift 5（进程、管道、FileHandle 等 C-API 交互密集，
// 与 Player/UI 保持同一约定，待接口稳定后统一迁移）。
import PackageDescription

let package = Package(
    name: "CatVodNode",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodNode", targets: ["CatVodNode"]),
    ],
    targets: [
        .target(
            name: "CatVodNode",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CatVodNodeTests",
            dependencies: ["CatVodNode"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
