// swift-tools-version: 6.0
// CatVodNet：请求管线（headers/hosts/DoH/proxy/ads）与本地 HTTP 服务。
// 说明：外部依赖（如 FlyingFox）按计划在 M6 引入，M0/M1 保持零外部依赖以确保 CI 稳定。
import PackageDescription

let package = Package(
    name: "CatVodNet",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodNet", targets: ["CatVodNet"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
    ],
    targets: [
        .target(
            name: "CatVodNet",
            dependencies: ["CatVodCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodNetTests",
            dependencies: ["CatVodNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
