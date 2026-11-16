// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Manzanero",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "manzanero", targets: ["Manzanero"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2")
    ],
    targets: [
        .target(name: "AppleDeviceBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Network"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("CoreImage"), .linkedFramework("IOKit")]),
        .executableTarget(name: "Manzanero", dependencies: [
            "AppleDeviceBridge",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Subprocess", package: "swift-subprocess")
        ]),
        .testTarget(name: "ManzaneroTests", dependencies: ["Manzanero"])
    ]
)
