// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "appledevicescmd",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "appledevicescmd", targets: ["AppleDevicesCMD"])],
    targets: [
        .executableTarget(name: "AppleDevicesCMD"),
        .testTarget(name: "AppleDevicesCMDTests", dependencies: ["AppleDevicesCMD"])
    ]
)
