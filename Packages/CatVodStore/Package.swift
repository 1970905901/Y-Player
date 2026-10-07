// swift-tools-version: 6.0
// CatVodStore：持久化（配置、收藏、历史、播放进度、搜索记录）。
//
// 依赖引入节奏：M2 启用 GRDB.swift（跨平台、便于单测）。
//   .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
import PackageDescription

let package = Package(
    name: "CatVodStore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodStore", targets: ["CatVodStore"])
    ],
    dependencies: [
        .package(path: "../CatVodCore")
    ],
    targets: [
        .target(
            name: "CatVodStore",
            dependencies: ["CatVodCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodStoreTests",
            dependencies: ["CatVodStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
