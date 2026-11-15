// swift-tools-version: 6.2
import PackageDescription

// UIKit-independent recording, summary and log logic for the probe app's touch probe.
// Its tests run on macOS with `swift test`; the app links only the ProbeCore library.
//
// Host-side measurement (macOS only, never linked into the app):
// - ProbeAnalysis: touch plans, log parsing and the sent-versus-received comparison (pure).
// - ProbeTouchRunner: drives Manzanero's CLI through an injected invoker and writes reports.
// - probe-touch: the command-line front end used by `mise run test:probe-touch`.
let package = Package(
    name: "ProbeCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ProbeCore", targets: ["ProbeCore"])],
    targets: [
        .target(name: "ProbeCore"),
        .target(name: "ProbeAnalysis", dependencies: ["ProbeCore"]),
        .target(name: "ProbeTouchRunner", dependencies: ["ProbeCore", "ProbeAnalysis"]),
        .executableTarget(name: "probe-touch", dependencies: ["ProbeTouchRunner"]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
        .testTarget(name: "ProbeMeasurementTests", dependencies: ["ProbeCore", "ProbeAnalysis", "ProbeTouchRunner"]),
    ],
    swiftLanguageModes: [.v6]
)
