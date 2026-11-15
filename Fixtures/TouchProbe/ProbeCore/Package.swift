// swift-tools-version: 6.2
import PackageDescription

// UIKit-independent recording, summary and log logic for the touch probe app.
// Its tests run on macOS with `swift test`; the app links the library.
let package = Package(
    name: "ProbeCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ProbeCore", targets: ["ProbeCore"])],
    targets: [
        .target(name: "ProbeCore"),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
    ],
    swiftLanguageModes: [.v6]
)
