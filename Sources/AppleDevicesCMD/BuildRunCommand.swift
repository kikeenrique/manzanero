import Foundation

/// Build orchestration stays separate from single device-operation planning.
struct BuildRunCommand {
    let physical: Bool
    let device: String
    let project: String
    let scheme: String
    let configuration: String
    let appTarget: String?

    static func parse(_ args: [String]) throws -> Self? {
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), args[2] == "build-run" else { return nil }
        guard args.count >= 5, (args.count - 5).isMultiple(of: 2) else {
            throw CommandFailure(description: "Usage: <physical|simulator> <UDID> build-run <project.xcodeproj|workspace.xcworkspace> <scheme> [--configuration <name>] [--app-target <name>]")
        }
        let physical = args[0] == "physical"
        let device = args[1]
        let validPhysicalID = device.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$", options: .regularExpression) != nil
            || device.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil
        guard UUID(uuidString: device) != nil || (physical && validPhysicalID) else {
            throw CommandFailure(description: "Build & Run requires an explicit device UDID or CoreDevice UUID, not a name or 'booted'.")
        }
        let project = args[3]
        guard ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: project).pathExtension),
              !project.hasPrefix("-"), !args[4].isEmpty, !args[4].hasPrefix("-") else {
            throw CommandFailure(description: "Provide an Xcode project/workspace path and a nonempty scheme.")
        }
        var flags: [String: String] = [:]
        for index in stride(from: 5, to: args.count, by: 2) {
            let key = args[index], value = args[index + 1]
            guard ["--configuration", "--app-target"].contains(key), flags[key] == nil,
                  !value.isEmpty, !value.hasPrefix("-") else {
                throw CommandFailure(description: "Unknown, repeated, or empty Build & Run option: \(key)")
            }
            flags[key] = value
        }
        return Self(physical: physical, device: device, project: project, scheme: args[4],
                    configuration: flags["--configuration"] ?? "Debug", appTarget: flags["--app-target"])
    }

    func xcodeArguments(directory: URL) -> [String] {
        ["xcodebuild", project.hasSuffix(".xcworkspace") ? "-workspace" : "-project", project,
         "-scheme", scheme, "-configuration", configuration,
         "-destination", "platform=\(physical ? "iOS" : "iOS Simulator"),id=\(device)",
         "-derivedDataPath", directory.appendingPathComponent("DerivedData").path,
         "-clonedSourcePackagesDirPath", directory.appendingPathComponent("SourcePackages").path,
         "-packageCachePath", directory.appendingPathComponent("PackageCache").path]
    }

    struct Product {
        let app: URL
        let bundleID: String
    }

    func product(settings data: Data) throws -> Product {
        struct Target: Decodable { let target: String; let buildSettings: [String: String] }
        let targets = try JSONDecoder().decode([Target].self, from: data).filter {
            $0.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.application"
                && (appTarget == nil || $0.target == appTarget)
        }
        guard targets.count == 1, let settings = targets.first?.buildSettings,
              let directory = settings["TARGET_BUILD_DIR"], directory.hasPrefix("/"),
              let name = settings["FULL_PRODUCT_NAME"], name.hasSuffix(".app"), !name.contains("/"),
              let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"], !bundleID.isEmpty, !bundleID.hasPrefix("-"),
              settings["PLATFORM_NAME"] == (physical ? "iphoneos" : "iphonesimulator") else {
            throw CommandFailure(description: "Build settings must identify exactly one iOS application for this destination. Use --app-target for multi-app schemes.")
        }
        return Product(app: URL(fileURLWithPath: directory).appendingPathComponent(name), bundleID: bundleID)
    }

    func execute(directory: URL, run: (DeviceCommand) throws -> Data,
                 build: ([String], URL) throws -> Void) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let args = xcodeArguments(directory: directory)
        let settings = try run(DeviceCommand(arguments: args + ["-showBuildSettings", "-json"], jsonOutput: true))
        let product = try product(settings: settings)
        try build(args + ["build"], directory.appendingPathComponent("build.log"))
        // Confirm the build output matches the selected target before changing the device.
        let data = try Data(contentsOf: product.app.appendingPathComponent("Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == product.bundleID,
              info?["CFBundlePackageType"] as? String == "APPL",
              let platforms = info?["CFBundleSupportedPlatforms"] as? [String],
              platforms.contains(physical ? "iPhoneOS" : "iPhoneSimulator") else {
            throw CommandFailure(description: "Built application metadata does not match the selected target/platform.")
        }
        let prefix = [physical ? "physical" : "simulator", device]
        guard let install = try DeviceCommand.parse(prefix + ["install", product.app.path]),
              var launch = try DeviceCommand.parse(prefix + ["launch", product.bundleID]) else {
            throw CommandFailure(description: "Cannot plan app deployment.")
        }
        // Rebuilding must run the new executable even if an older copy is open.
        launch.arguments.insert(physical ? "--terminate-existing" : "--terminate-running-process", at: physical ? 4 : 2)
        _ = try run(install)
        let launched = try run(launch)
        let launchResult: Any = physical ? try JSONSerialization.jsonObject(with: launched) : String(decoding: launched, as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": "launched", "backend": "xcode",
            "device": device, "bundleIdentifier": product.bundleID, "appPath": product.app.path,
            "buildDirectory": directory.path, "launch": launchResult, "verified": false], options: [.prettyPrinted, .sortedKeys])
    }
}
