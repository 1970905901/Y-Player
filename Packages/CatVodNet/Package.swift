// swift-tools-version: 6.0
// CatVodNet：请求管线（headers/proxy/ads）+ 本地 HTTP 服务（M6 起用 FlyingFox）。
// `hosts` 覆盖与 `doh` 是**已知平台缺口**（URLSession 没有 DNS 钩子），见 M06m 记录。
// 说明：M0/M1 保持零外部依赖以确保 CI 稳定；M6 按计划引入 FlyingFox（MIT，iOS 13+/macOS 10.15+）。
import PackageDescription

let package = Package(
    name: "CatVodNet",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CatVodNet", targets: ["CatVodNet"]),
    ],
    dependencies: [
        .package(path: "../CatVodCore"),
        // 本地 HTTP 服务（M6）：FlyingFox（MIT）。按仓库约定用精确版本锁定，
        // 升级必须在 docs/任务记录 里留痕（对照 MPVKit 的 ThirdParty/mpvkit.lock.json 做法）。
        .package(url: "https://github.com/swhitty/FlyingFox.git", exact: "0.27.1"),
    ],
    targets: [
        .target(
            name: "CatVodNet",
            dependencies: [
                "CatVodCore",
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatVodNetTests",
            // 测试里要直接构造 FlyingFox 的 HTTPRequest/HTTPResponse（本地代理的端点契约就是它们），
            // 因此显式声明依赖，而不是靠传递依赖。
            dependencies: [
                "CatVodNet",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
