// swift-tools-version: 6.0
// CatVodUI：跨端 SwiftUI 组件与平台差异 shim（iOS 15 / macOS 13）。
import PackageDescription

let package = Package(
    name: "CatVodUI",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodUI", targets: ["CatVodUI"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        // CatVodNet 本来是经 CatVodPlayer 传递进来的隐式依赖（`import CatVodNet` 一直能用），
        // M6 起 UI 直接用它的本地服务（`LocalHTTPServer`），这里显式声明，避免依赖形态变化后突然编译不过。
        .package(path: "../CatVodNet"),
        .package(path: "../CatVodSource"),
        .package(path: "../CatVodPlayer"),
        .package(path: "../CatVodStore"),
    ],
    targets: [
        .target(
            name: "CatVodUI",
            dependencies: ["CatVodCore", "CatVodNet", "CatVodSource", "CatVodPlayer", "CatVodStore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CatVodUITests",
            dependencies: ["CatVodUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
