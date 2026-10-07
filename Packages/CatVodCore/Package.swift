// swift-tools-version: 6.0
// CatVodCore：协议核心（零外部依赖、仅 Foundation），可在任意 Swift 平台单测。
import PackageDescription

let package = Package(
    name: "CatVodCore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodCore", targets: ["CatVodCore"])
    ],
    targets: [
        .target(
            name: "CatVodCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodCoreTests",
            dependencies: ["CatVodCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
