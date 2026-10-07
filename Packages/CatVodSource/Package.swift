// swift-tools-version: 6.0
// CatVodSource：站点客户端（type 0/1/2/4）、js2p 宿主与 JS 运行时、解析与嗅探、直播源解析。
//
// 依赖 CatVodNode：js2p 宿主会话（``JS2PHostService``）需要它提供的进程级 Node 运行时。
import PackageDescription

let package = Package(
    name: "CatVodSource",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodSource", targets: ["CatVodSource"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        .package(path: "../CatVodNet"),
        .package(path: "../CatVodNode"),
    ],
    targets: [
        .target(
            name: "CatVodSource",
            dependencies: ["CatVodCore", "CatVodNet", "CatVodNode"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodSourceTests",
            dependencies: ["CatVodSource", "CatVodNode"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
