// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Manzanero",
    // Every device operation goes through Xcode 27 or later, which runs on
    // Apple silicon with macOS 26.6 or later.
    platforms: [.macOS("26.6")],
    products: [.executable(name: "manzanero", targets: ["Manzanero"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        // lwIP with a Swift package manifest and a small C surface, from the
        // human owner's fork: TCP over IPv6 in user space for the tool's own tunnel.
        .package(url: "https://github.com/kikeenrique/lwip.git", exact: "2.2.1-swiftpm-dev.1")
    ],
    targets: [
        .target(name: "AppleDeviceBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Network"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("CoreImage"), .linkedFramework("IOKit")]),
        .executableTarget(name: "Manzanero", dependencies: [
            "AppleDeviceBridge",
            .product(name: "CLwIP", package: "lwip"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Subprocess", package: "swift-subprocess")
        ]),
        .testTarget(name: "ManzaneroTests", dependencies: ["Manzanero", .product(name: "CLwIP", package: "lwip")])
    ]
)
