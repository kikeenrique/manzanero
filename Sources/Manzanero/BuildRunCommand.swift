import Foundation

/// Build orchestration stays separate from single device-operation planning.
struct BuildRunCommand: Sendable, Equatable {
    static let provisioningUpdatesFlag = "--allow-provisioning-updates"
    static let deviceRegistrationFlag = "--allow-device-registration"

    let physical: Bool
    let device: String
    let project: String
    let scheme: String
    let configuration: String
    let appTarget: String?
    /// Lets xcodebuild sign in to Apple's developer services with the account in Xcode's settings
    /// and create or update certificates, app IDs and provisioning profiles.
    var allowProvisioningUpdates = false
    /// Lets xcodebuild register the destination device with the team; requires provisioning updates.
    var allowDeviceRegistration = false
    /// Identifier passed to xcodebuild's `-destination id=`. xcodebuild documents the identifier
    /// shown in Xcode's Devices window (the hardware UDID for a physical device); a CoreDevice
    /// UUID is resolved to it before building. devicectl accepts either and keeps `device`.
    var destinationID: String

    /// Checks the target, paths and options before anything is built.
    init(physical: Bool, device: String, project: String, scheme: String, configuration: String?, appTarget: String?,
         allowProvisioningUpdates: Bool = false, allowDeviceRegistration: Bool = false) throws {
        guard UUID(uuidString: device) != nil || (physical && Self.isHardwareUDID(device)) else {
            throw CommandFailure.usage("Build & Run requires an explicit device UDID or CoreDevice UUID, not a name or 'booted'.")
        }
        guard ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: project).pathExtension),
              !project.hasPrefix("-"), !scheme.isEmpty, !scheme.hasPrefix("-") else {
            throw CommandFailure.usage("Provide an Xcode project/workspace path and a nonempty scheme.")
        }
        for (key, value) in [("--configuration", configuration), ("--app-target", appTarget)] {
            if let value, value.isEmpty || value.hasPrefix("-") {
                throw CommandFailure.usage("Unknown, repeated, or empty Build & Run option: \(key)")
            }
        }
        let switches = [allowProvisioningUpdates ? Self.provisioningUpdatesFlag : nil, allowDeviceRegistration ? Self.deviceRegistrationFlag : nil]
            .compactMap { $0 }
        if !physical, !switches.isEmpty {
            throw CommandFailure.usage("Provisioning options (\(switches.sorted().joined(separator: ", "))) apply only to physical devices; simulator builds need no provisioning profile.")
        }
        if allowDeviceRegistration, !allowProvisioningUpdates {
            throw CommandFailure.usage("\(Self.deviceRegistrationFlag) requires \(Self.provisioningUpdatesFlag); xcodebuild ignores device registration without provisioning updates.")
        }
        self.init(physical: physical, device: device, project: project, scheme: scheme,
                  configuration: configuration ?? "Debug", appTarget: appTarget,
                  allowProvisioningUpdates: allowProvisioningUpdates, allowDeviceRegistration: allowDeviceRegistration,
                  destinationID: device)
    }

    init(physical: Bool, device: String, project: String, scheme: String, configuration: String, appTarget: String?,
         allowProvisioningUpdates: Bool, allowDeviceRegistration: Bool, destinationID: String) {
        self.physical = physical; self.device = device; self.project = project; self.scheme = scheme
        self.configuration = configuration; self.appTarget = appTarget
        self.allowProvisioningUpdates = allowProvisioningUpdates; self.allowDeviceRegistration = allowDeviceRegistration
        self.destinationID = destinationID
    }

    static func isHardwareUDID(_ value: String) -> Bool {
        value.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil
    }

    /// True for a physical CoreDevice UUID that must become a hardware UDID before xcodebuild sees it.
    var requiresDestinationResolution: Bool { physical && destinationID == device && UUID(uuidString: device) != nil }

    /// Resolves the hardware UDID from `devicectl device info details` JSON for the requested CoreDevice UUID.
    func resolvingDestination(details data: Data) throws -> Self {
        let failure = CommandFailure(.targetUnresolved, "Cannot resolve the hardware UDID for CoreDevice UUID \(device), which xcodebuild's -destination needs. Pass the device's hardware UDID (hardwareProperties.udid in `manzanero details --device \(device)`) instead.", inputSent: .none)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any],
              let identifier = (result["identifier"] as? String).flatMap(UUID.init(uuidString:)),
              identifier == UUID(uuidString: device) else { throw failure }
        let hardware = ((result["properties"] as? [String: Any])?["hardware"] as? [String: Any])
            ?? (result["hardwareProperties"] as? [String: Any])
        guard let udid = hardware?["udid"] as? String, Self.isHardwareUDID(udid) else { throw failure }
        var resolved = self
        resolved.destinationID = udid
        return resolved
    }

    /// The platforms a build may be for, as build settings name them
    /// (`PLATFORM_NAME`) and as a built app's Info.plist does
    /// (`CFBundleSupportedPlatforms`): a device's or a simulator's, of any
    /// family. xcodebuild finds the family from the destination's identifier.
    static let devicePlatforms = ["iphoneos": "iPhoneOS", "appletvos": "AppleTVOS", "watchos": "WatchOS", "xros": "XROS"]
    static let simulatorPlatforms = ["iphonesimulator": "iPhoneSimulator", "appletvsimulator": "AppleTVSimulator",
                                     "watchsimulator": "WatchSimulator", "xrsimulator": "XRSimulator"]
    var platforms: [String: String] { physical ? Self.devicePlatforms : Self.simulatorPlatforms }

    func xcodeArguments(directory: URL) -> [String] {
        ["xcodebuild", project.hasSuffix(".xcworkspace") ? "-workspace" : "-project", project,
         "-scheme", scheme, "-configuration", configuration,
         "-destination", "id=\(destinationID)",
         "-derivedDataPath", directory.appendingPathComponent("DerivedData").path,
         "-clonedSourcePackagesDirPath", directory.appendingPathComponent("SourcePackages").path,
         "-packageCachePath", directory.appendingPathComponent("PackageCache").path]
    }

    /// Provisioning flags apply to the build only; the settings query neither signs nor contacts Apple.
    var provisioningArguments: [String] {
        (allowProvisioningUpdates ? ["-allowProvisioningUpdates"] : [])
            + (allowDeviceRegistration ? ["-allowProvisioningDeviceRegistration"] : [])
    }

    func settingsArguments(directory: URL) -> [String] { xcodeArguments(directory: directory) + ["-showBuildSettings", "-json"] }
    func buildArguments(directory: URL) -> [String] { xcodeArguments(directory: directory) + provisioningArguments + ["build"] }

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
              let platform = settings["PLATFORM_NAME"], platforms[platform] != nil else {
            throw CommandFailure.usage("Build settings must identify exactly one application for this destination (a device build for a device, a simulator build for a simulator). Use --app-target for multi-app schemes.")
        }
        return Product(app: URL(fileURLWithPath: directory).appendingPathComponent(name), bundleID: bundleID)
    }

    /// Install and launch plans. Launch terminates a running copy so a rebuild runs the new executable.
    func deploymentPlan(app: String, bundleID: String) throws -> (install: DeviceCommand, launch: DeviceCommand) {
        let install = try DeviceCommand.plan(physical: physical, device: device, operation: "install", operands: [app])
        var launch = try DeviceCommand.plan(physical: physical, device: device, operation: "launch", operands: [bundleID])
        // devicectl: options precede the app operand, which ends devicectl's own options.
        launch.arguments.insert(physical ? "--terminate-existing" : "--terminate-running-process", at: physical ? 4 : 2)
        return (install, launch)
    }

    func dryRunPlan(directory: URL) throws -> [String: Any] {
        let deployment = try deploymentPlan(app: "<TARGET_BUILD_DIR>/<FULL_PRODUCT_NAME>", bundleID: "<PRODUCT_BUNDLE_IDENTIFIER>")
        var plan: [String: Any] = ["executable": "/usr/bin/xcrun",
            "buildSettingsArguments": settingsArguments(directory: directory),
            "buildArguments": buildArguments(directory: directory),
            "installArguments": deployment.install.arguments, "launchArguments": deployment.launch.arguments,
            "deployment": "After a successful build, resolve the application from build settings, install it, and launch its bundle identifier, terminating a running copy first."]
        if physical {
            plan["provisioning"] = [
                "allowProvisioningUpdates": allowProvisioningUpdates, "allowDeviceRegistration": allowDeviceRegistration,
                "effect": allowProvisioningUpdates
                    ? "xcodebuild signs in to Apple's developer services with the account in Xcode's settings and may create or update certificates, app IDs and provisioning profiles"
                        + (allowDeviceRegistration ? ", and register this device with the team." : "; it will not register the device.")
                    : "Uses only signing assets already on this Mac; Apple's developer services are not contacted."] as [String: Any]
        }
        if requiresDestinationResolution {
            plan["destinationResolution"] = "Before the build, the CoreDevice UUID is resolved to the hardware UDID from devicectl device details and replaces id= in both xcodebuild invocations; devicectl keeps the CoreDevice UUID."
        }
        return plan
    }

    /// Maps xcodebuild log text to likely causes and the next step; empty when nothing is recognised.
    func failureHints(log text: String) -> [String] { failureFindings(log: text).map(\.hint) }

    /// The likely causes in `failureHints` order, each marked when it is a
    /// signing or provisioning problem rather than a missing destination.
    func failureFindings(log text: String) -> [(hint: String, signing: Bool)] {
        func has(_ needles: String...) -> Bool { needles.contains { text.range(of: $0, options: .caseInsensitive) != nil } }
        var findings: [(hint: String, signing: Bool)] = []
        if has("Unable to find a destination matching", "Unable to find a device matching") {
            findings.append(("xcodebuild did not find the destination: check that the device is connected, unlocked and trusted, and pass its hardware UDID.", false))
        }
        guard physical else { return findings }
        let updates = Self.provisioningUpdatesFlag, register = Self.deviceRegistrationFlag
        if has("requires a development team") {
            findings.append(("No development team: set DEVELOPMENT_TEAM in the project or an xcconfig. \(updates) cannot choose a team.", true))
        }
        if has("No Accounts", "No account for team", "session has expired") {
            findings.append(("Xcode has no usable account for the team: sign in under Xcode > Settings > Accounts. Provisioning updates use that account.", true))
        }
        if has("No signing certificate", "signing certificate matching team", "No certificate for team") {
            findings.append((allowProvisioningUpdates
                ? "No usable development certificate, and Xcode could not create one: check the account's role in the team."
                : "No usable development certificate on this Mac: rerun with \(updates) to let Xcode create one.", true))
        }
        if has("isn't registered in your developer account", "is not registered in your developer account",
               "has no devices from which to generate a provisioning profile", "doesn't include the currently selected device") {
            findings.append((allowDeviceRegistration
                ? "The device is not in the profile even with registration allowed: check the team's device list and limit."
                : "The device is not registered with the team or not in the profile: rerun with \(updates) \(register) to register it and regenerate the profile.", true))
        }
        if has("No profiles for", "No matching provisioning profiles found", "requires a provisioning profile",
               "unable to generate a profile", "Automatic signing is disabled") {
            findings.append((allowProvisioningUpdates
                ? "Xcode could not create a provisioning profile for this bundle identifier and team."
                : "No development provisioning profile for this bundle identifier on this Mac: rerun with \(updates) to let Xcode create it.", true))
        }
        if has("cannot be registered to your development team", "Failed Registering Bundle Identifier") {
            findings.append(("The bundle identifier is taken by another team: choose one your team can register.", true))
        }
        return findings
    }

    func execute(directory: URL, run: (DeviceCommand) throws -> Data,
                 build: ([String], URL) throws -> Void) throws -> Data {
        // Everything before install runs on the Mac and leaves the device alone.
        let product: Product
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = try run(DeviceCommand(arguments: settingsArguments(directory: directory), jsonOutput: true))
            product = try self.product(settings: settings)
            let log = directory.appendingPathComponent("build.log")
            do {
                try build(buildArguments(directory: directory), log)
            } catch {
                // Keep the raw failure (including its log path) and add likely causes when the log names them.
                guard let data = try? Data(contentsOf: log) else { throw error }
                let findings = failureFindings(log: String(decoding: data, as: UTF8.self))
                guard !findings.isEmpty else { throw error }
                let description = "\(error) Likely cause: \(findings.map(\.hint).joined(separator: " "))"
                throw findings.contains(where: \.signing)
                    ? CommandFailure(.signingFailed, description, inputSent: .none)
                    : CommandFailure(description, wrapping: error)
            }
        } catch let failure as CommandFailure {
            throw failure.noInputSent()
        }
        // Confirm the build output matches the selected target before changing the device.
        let data = try Data(contentsOf: product.app.appendingPathComponent("Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == product.bundleID,
              info?["CFBundlePackageType"] as? String == "APPL",
              let supported = info?["CFBundleSupportedPlatforms"] as? [String],
              supported.contains(where: platforms.values.contains) else {
            throw CommandFailure(.toolFailed, "Built application metadata does not match the selected target/platform.", inputSent: .none)
        }
        let deployment = try deploymentPlan(app: product.app.path, bundleID: product.bundleID)
        _ = try run(deployment.install)
        let launched = try run(deployment.launch)
        let launchResult: Any = physical ? try JSONSerialization.jsonObject(with: launched) : String(decoding: launched, as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": "launched", "backend": "xcode",
            "device": device, "buildDestination": destinationID, "bundleIdentifier": product.bundleID, "appPath": product.app.path,
            "buildDirectory": directory.path, "launch": launchResult, "verified": false], options: [.prettyPrinted, .sortedKeys])
    }
}
