// swift-tools-version: 6.0
// CatVodUI：跨端 SwiftUI 组件与平台差异 shim（iOS 15 / macOS 13）。
import PackageDescription

let package = Package(
    name: "CatVodUI",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodUI", targets: ["CatVodUI"])
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        .package(path: "../CatVodSource"),
        .package(path: "../CatVodPlayer")
    ],
    targets: [
        .target(
            name: "CatVodUI",
            dependencies: ["CatVodCore", "CatVodSource", "CatVodPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CatVodUITests",
            dependencies: ["CatVodUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
