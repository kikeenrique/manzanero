import AppleDeviceBridge
import Darwin
import Foundation

/// One dynamically resolved Apple interface from the bridge's capability table.
struct PrivateInterfaceRequirement: Sendable, Equatable {
    enum Kind: String, Sendable { case framework, symbol, objcClass, instanceMethod, classMethod }
    let kind: Kind
    let name: String
    var owner: String? = nil
    var required = true
    let available: Bool

    /// Framework path, symbol or class name; methods use `-[Class selector]` / `+[Class selector]`.
    var displayName: String {
        switch kind {
        case .instanceMethod: "-[\(owner ?? "?") \(name)]"
        case .classMethod: "+[\(owner ?? "?") \(name)]"
        case .framework, .symbol, .objcClass: name
        }
    }
}

struct PrivateCapability: Sendable, Equatable {
    let identifier: String
    let summary: String
    var minimumMacOSMajor: Int? = nil
    var usedByCommands = true
    let requirements: [PrivateInterfaceRequirement]

    enum Status: String, Sendable { case available, degraded, missing, unsupportedHost = "unsupported-host" }

    func status(macOSMajor: Int) -> Status {
        if let minimumMacOSMajor, macOSMajor < minimumMacOSMajor { return .unsupportedHost }
        if requirements.contains(where: { $0.required && !$0.available }) { return .missing }
        if requirements.contains(where: { !$0.available }) { return .degraded }
        return .available
    }
}

enum PrivateInterfaces {
    /// Runs the bridge's host-only check. Loads frameworks; contacts no device.
    static func check() -> [PrivateCapability] {
        var capabilities: [PrivateCapability] = []
        ADCCheckCapabilities { pointer in
            guard let check = pointer?.pointee else { return }
            var requirements: [PrivateInterfaceRequirement] = []
            for index in 0..<check.requirementCount {
                guard let raw = check.requirements?[index] else { continue }
                requirements.append(PrivateInterfaceRequirement(
                    kind: kind(raw.kind), name: raw.name.map { String(cString: $0) } ?? "",
                    owner: raw.owner.map { String(cString: $0) }, required: raw.required != 0, available: raw.available != 0))
            }
            capabilities.append(PrivateCapability(
                identifier: check.identifier.map { String(cString: $0) } ?? "",
                summary: check.summary.map { String(cString: $0) } ?? "",
                minimumMacOSMajor: check.minimumMacOSMajor > 0 ? Int(check.minimumMacOSMajor) : nil,
                usedByCommands: check.usedByCommands != 0, requirements: requirements))
        }
        return capabilities
    }

    private static func kind(_ raw: Int32) -> PrivateInterfaceRequirement.Kind {
        switch Int(raw) {
        case ADCInterfaceFramework: .framework
        case ADCInterfaceClass: .objcClass
        case ADCInterfaceInstanceMethod: .instanceMethod
        case ADCInterfaceClassMethod: .classMethod
        default: .symbol
        }
    }
}

/// Facts that explain a doctor result. Read without private calls.
struct DoctorHost: Sendable {
    var macOS: OperatingSystemVersion
    var macOSBuild: String? = nil
    var xcodeVersion: String? = nil
    var xcodeBuild: String? = nil
    var coreDeviceVersion: String? = nil
    var avConferenceVersion: String? = nil

    var macOSVersionString: String {
        let version = macOS
        return version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `xcodebuild -version` prints `Xcode <version>` and `Build version <build>`.
    static func parseXcode(_ output: Data) -> (version: String?, build: String?) {
        var version: String?, build: String?
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Xcode "), version == nil { version = String(text.dropFirst(6)) }
            if text.hasPrefix("Build version "), build == nil { build = String(text.dropFirst(14)) }
        }
        return (version, build)
    }

    /// Reads Info.plist only; Bundle(path:) does not load the framework's code.
    /// CFBundleVersion is the build number Apple reports (e.g. AVConference's
    /// avcFrameworkVersion); the marketing version is only a fallback.
    static func bundleVersion(_ path: String) -> String? {
        guard let info = Bundle(path: path)?.infoDictionary else { return nil }
        return (info["CFBundleVersion"] ?? info["CFBundleShortVersionString"]) as? String
    }

    static func current(xcodeOutput: Data?) -> DoctorHost {
        var size = 0
        var build: String?
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 {
                build = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        let xcode: (version: String?, build: String?) = xcodeOutput.map(parseXcode) ?? (nil, nil)
        return DoctorHost(macOS: ProcessInfo.processInfo.operatingSystemVersion, macOSBuild: build,
                          xcodeVersion: xcode.version, xcodeBuild: xcode.build,
                          coreDeviceVersion: bundleVersion("/Library/Developer/PrivateFrameworks/CoreDevice.framework"),
                          avConferenceVersion: bundleVersion("/System/Library/PrivateFrameworks/AVConference.framework"))
    }
}

/// `doctor`: Apple tool checks, host facts and private-interface availability.
/// Output stays a JSON array; the three tool entries keep their original keys.
/// Exit code is 1 only when an entry has status "unavailable", which only tool
/// entries use. Private capabilities report available/degraded/missing/
/// unsupported-host and never change the exit code.
enum Doctor {
    struct ToolCheck: Sendable {
        let name: String
        var failure: String? = nil
    }

    static let tools: [(name: String, arguments: [String])] = [
        ("Xcode", ["xcodebuild", "-version"]),
        ("CoreDevice", ["devicectl", "list", "devices", "--timeout", "5", "--json-output", "-"]),
        ("CoreSimulator", ["simctl", "list", "devices", "available", "--json"])
    ]

    static func run(_ runTool: ([String]) throws -> Data,
                    capabilities: () -> [PrivateCapability] = PrivateInterfaces.check) throws -> CommandOutput {
        var checks: [ToolCheck] = []
        var xcodeOutput: Data?
        for tool in tools {
            do {
                let output = try runTool(tool.arguments)
                if tool.name == "Xcode" { xcodeOutput = output }
                checks.append(ToolCheck(name: tool.name))
            } catch {
                checks.append(ToolCheck(name: tool.name, failure: String(describing: error)))
            }
        }
        return try report(tools: checks, host: .current(xcodeOutput: xcodeOutput), capabilities: capabilities())
    }

    static func report(tools: [ToolCheck], host: DoctorHost, capabilities: [PrivateCapability]) throws -> CommandOutput {
        var entries: [[String: Any]] = tools.map { tool in
            var entry: [String: Any] = ["name": tool.name, "kind": "tool", "status": tool.failure == nil ? "available" : "unavailable"]
            if let failure = tool.failure { entry["detail"] = failure }
            return entry
        }
        var hostEntry: [String: Any] = ["name": "Host", "kind": "host", "status": "reported", "macOSVersion": host.macOSVersionString]
        for (key, value) in [("macOSBuild", host.macOSBuild), ("xcodeVersion", host.xcodeVersion), ("xcodeBuild", host.xcodeBuild),
                             ("coreDeviceVersion", host.coreDeviceVersion), ("avConferenceVersion", host.avConferenceVersion)] {
            if let value { hostEntry[key] = value }
        }
        entries.append(hostEntry)
        for capability in capabilities {
            let status = capability.status(macOSMajor: host.macOS.majorVersion)
            var entry: [String: Any] = [
                "name": capability.identifier, "kind": "private-interface", "status": status.rawValue,
                "summary": capability.summary, "usedByCommands": capability.usedByCommands,
                "checked": capability.requirements.count,
                "missing": capability.requirements.filter { $0.required && !$0.available }.map(\.displayName),
                "optionalMissing": capability.requirements.filter { !$0.required && !$0.available }.map(\.displayName)
            ]
            if let minimum = capability.minimumMacOSMajor {
                entry["minimumMacOS"] = "\(minimum)"
                if status == .unsupportedHost {
                    entry["detail"] = "Requires macOS \(minimum) or later; this host runs \(host.macOSVersionString)."
                }
            }
            entries.append(entry)
        }
        var output = CommandOutput(data: try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]))
        if entries.contains(where: { $0["status"] as? String == "unavailable" }) { output.exitCode = 1 }
        return output
    }
}
