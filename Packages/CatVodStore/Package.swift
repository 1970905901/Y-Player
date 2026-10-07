// swift-tools-version: 6.0
// CatVodStore：持久化（站点、收藏、历史、播放进度、搜索记录）。
//
// 依赖引入节奏：M8 启用 GRDB.swift（SQLite 封装，跨平台、便于单测）。
// 版本与来源登记在 ThirdParty/grdb.lock.json；升级必须同步更新并在 docs/任务记录 留痕。
import PackageDescription

let package = Package(
    name: "CatVodStore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodStore", targets: ["CatVodStore"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        // GRDB 7.11.1（MIT）。要求 Swift 6.1 / Xcode 16.3+，与本仓库基线（Xcode 16.4）一致。
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CatVodStore",
            dependencies: ["CatVodCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodStoreTests",
            dependencies: ["CatVodStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
