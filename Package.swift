// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "appledevicescmd",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "appledevicescmd", targets: ["AppleDevicesCMD"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2")
    ],
    targets: [
        .executableTarget(name: "AppleDevicesCMD", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Subprocess", package: "swift-subprocess")
        ]),
        .testTarget(name: "AppleDevicesCMDTests", dependencies: ["AppleDevicesCMD"])
    ]
)
