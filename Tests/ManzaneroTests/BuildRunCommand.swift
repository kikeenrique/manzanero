import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

struct BuildRunCommandTests {
    let device = "11111111-2222-3333-4444-555555555555"

    func request(appTarget: String? = nil) throws -> BuildRunCommand {
        try BuildRunCommand(physical: false, device: device, project: "tmp/My App.xcodeproj", scheme: "My App", configuration: nil, appTarget: appTarget)
    }

    /// A physical build of `A.xcodeproj`'s scheme `A` (or the given project and scheme).
    static func physical(_ device: String = "00000000-0000000000000000", project: String = "A.xcodeproj", scheme: String = "A",
                         configuration: String? = nil, updates: Bool = false, registration: Bool = false) throws -> BuildRunCommand {
        try BuildRunCommand(physical: true, device: device, project: project, scheme: scheme, configuration: configuration, appTarget: nil,
                            allowProvisioningUpdates: updates, allowDeviceRegistration: registration)
    }

    func settings(directory: URL, targets: [String] = ["My App"], platform: String = "iphonesimulator") throws -> Data {
        try JSONSerialization.data(withJSONObject: targets.map { target in
            ["target": target, "buildSettings": ["PRODUCT_TYPE": "com.apple.product-type.application",
                "TARGET_BUILD_DIR": directory.path, "FULL_PRODUCT_NAME": "My App.app",
                "PRODUCT_BUNDLE_IDENTIFIER": "org.example.build-run", "PLATFORM_NAME": platform]]
        })
    }

    func fixture(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/build-run-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func writeApp(_ directory: URL, bundle: String = "org.example.build-run") throws {
        let app = directory.appendingPathComponent("My App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle,
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    }

    @Test func pathsAndSchemeAreLiteralArguments() throws {
        let command = try BuildRunCommand(physical: false, device: device, project: "tmp/$(touch sentinel).xcworkspace", scheme: "My App; echo x",
                                          configuration: "Custom Debug", appTarget: nil)
        let args = command.xcodeArguments(directory: URL(fileURLWithPath: "/project/tmp/build"))
        #expect(args.prefix(7) == ["xcodebuild", "-workspace", "tmp/$(touch sentinel).xcworkspace", "-scheme", "My App; echo x", "-configuration", "Custom Debug"])
        #expect(args.contains("id=\(device)"))
        // A device build is refused for a simulator, whatever the family, and
        // an Apple TV's build is taken for an Apple TV simulator.
        #expect(command.platforms["appletvsimulator"] == "AppleTVSimulator" && command.platforms["iphoneos"] == nil)
        #expect(args.contains("-allowProvisioningUpdates") == false)
    }

    /// Command lines the parser or Build & Run refuses before anything is built.
    @Test(arguments: [
        ["build-run", "A.xcodeproj", "A", "--simulator", "booted"],
        ["build-run", "A.xcodeproj", "A", "--device", "x,id=other"],
        ["build-run", "A.xcodeproj", "--simulator", "11111111-2222-3333-4444-555555555555"],
        ["build-run", "A", "A", "--simulator", "11111111-2222-3333-4444-555555555555"],
        ["build-run", "A.xcodeproj", "A", "--unknown", "x", "--simulator", "11111111-2222-3333-4444-555555555555"],
        ["build-run", "A.xcodeproj", "A", "--simulator", "11111111-2222-3333-4444-555555555555", "--configuration"],
        ["build-run", "A.xcodeproj", "A", "--configuration=-x", "--simulator", "11111111-2222-3333-4444-555555555555"],
        ["build-run", "A.xcodeproj", "A", "--allow-provisioning-updates=YES", "--device", "00000000-0000000000000000"],
        ["build-run", "A.xcodeproj", "A", "--device", "00000000-0000000000000000", "--configuration", "--allow-provisioning-updates"]
    ]) func invalidRequestsAreRejected(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try CLI.invocation(args) }
    }

    @Test func defaultBuildDoesNotContactDeveloperServices() throws {
        let command = try Self.physical()
        let build = command.buildArguments(directory: URL(fileURLWithPath: "/project/tmp/build"))
        #expect(build.last == "build")
        #expect(!build.contains("-allowProvisioningUpdates"))
        #expect(!build.contains("-allowProvisioningDeviceRegistration"))
    }

    @Test func provisioningFlagsReachOnlyTheBuildInvocation() throws {
        let command = try Self.physical(configuration: "Release", updates: true, registration: true)
        let directory = URL(fileURLWithPath: "/project/tmp/build")
        #expect(command.configuration == "Release")
        #expect(command.buildArguments(directory: directory).suffix(3) == ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"])
        let settings = command.settingsArguments(directory: directory)
        #expect(!settings.contains("-allowProvisioningUpdates"))
        #expect(settings.suffix(2) == ["-showBuildSettings", "-json"])
        let updatesOnly = try Self.physical(updates: true)
        #expect(updatesOnly.buildArguments(directory: directory).suffix(2) == ["-allowProvisioningUpdates", "build"])
    }

    @Test func deviceRegistrationRequiresProvisioningUpdates() {
        #expect {
            try Self.physical(registration: true)
        } throws: { String(describing: $0).contains("requires --allow-provisioning-updates") }
    }

    @Test(arguments: [(true, false), (true, true), (false, true)])
    func provisioningFlagsAreRejectedForSimulators(_ updates: Bool, _ registration: Bool) {
        #expect {
            try BuildRunCommand(physical: false, device: "11111111-2222-3333-4444-555555555555", project: "A.xcodeproj", scheme: "A",
                                configuration: nil, appTarget: nil, allowProvisioningUpdates: updates, allowDeviceRegistration: registration)
        } throws: { String(describing: $0).contains("apply only to physical devices") }
    }

    func details(identifier: String, udid: String, legacy: Bool = false, outcome: String = "success") throws -> Data {
        var result: [String: Any] = ["identifier": identifier]
        if legacy { result["hardwareProperties"] = ["udid": udid] } else { result["properties"] = ["hardware": ["udid": udid]] }
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": outcome], "result": result])
    }

    @Test func coreDeviceUUIDIsResolvedToHardwareUDIDForXcodeOnly() throws {
        let coreDevice = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", udid = "00000000-0000000000000000"
        let command = try Self.physical(coreDevice)
        #expect(command.requiresDestinationResolution)
        for legacy in [false, true] {
            let resolved = try command.resolvingDestination(details: details(identifier: coreDevice.lowercased(), udid: udid, legacy: legacy))
            #expect(!resolved.requiresDestinationResolution)
            #expect(resolved.xcodeArguments(directory: URL(fileURLWithPath: "/b")).contains("id=\(udid)"))
            let deployment = try resolved.deploymentPlan(app: "/b/A.app", bundleID: "org.example.a")
            #expect(deployment.install.arguments.contains(coreDevice))
            #expect(deployment.launch.arguments.contains(coreDevice))
        }
        for bad in [try details(identifier: "11111111-2222-3333-4444-555555555555", udid: udid),
                    try details(identifier: coreDevice, udid: "not-a-udid"),
                    try details(identifier: coreDevice, udid: udid, outcome: "failed"), Data()] {
            #expect { try command.resolvingDestination(details: bad) } throws: { String(describing: $0).contains("hardware UDID") }
        }
        let hardware = try Self.physical(udid)
        #expect(!hardware.requiresDestinationResolution)
        let simulator = try request()
        #expect(!simulator.requiresDestinationResolution)
    }

    @Test func physicalSigningFailuresNameTheCauseAndKeepTheLogPath() throws {
        try fixture { directory in
            let command = try Self.physical(project: "App.xcodeproj", scheme: "App")
            var deployed = false
            #expect {
                try command.execute(directory: directory, run: { plan in
                    guard plan.arguments.contains("-showBuildSettings") else { deployed = true; return Data() }
                    return try settings(directory: directory, platform: "iphoneos")
                }, build: { _, log in
                    try Data("error: No profiles for 'org.example.build-run' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'org.example.build-run'.\n".utf8).write(to: log)
                    throw CommandFailure(description: "Xcode build failed (65); raw build log: \(log.path)")
                })
            } throws: { error in
                let text = String(describing: error)
                return text.contains("raw build log: \(directory.appendingPathComponent("build.log").path)")
                    && text.contains("rerun with --allow-provisioning-updates")
            }
            #expect(!deployed)
        }
    }

    @Test func signingHintsDependOnFlagsAndPlatform() throws {
        let plain = try Self.physical()
        let updating = try Self.physical(updates: true)
        let team = "Signing for \"A\" requires a development team. Select a development team in the Signing & Capabilities editor."
        #expect(plain.failureHints(log: team).count == 1)
        #expect(plain.failureHints(log: team).first?.contains("DEVELOPMENT_TEAM") == true)
        let device = "Your team has no devices from which to generate a provisioning profile."
        #expect(plain.failureHints(log: device).first?.contains("--allow-provisioning-updates --allow-device-registration") == true)
        #expect(updating.failureHints(log: device).first?.contains("--allow-device-registration") == true)
        let profile = "No profiles for 'org.example.a' were found"
        #expect(updating.failureHints(log: profile).first?.contains("rerun") == false)
        #expect(plain.failureHints(log: "error: Swift compiler error").isEmpty)
        #expect(try request().failureHints(log: profile).isEmpty)
    }

    @Test func unrecognisedBuildFailureIsRethrownUnchanged() throws {
        try fixture { directory in
            let command = try Self.physical(project: "App.xcodeproj", scheme: "App")
            #expect {
                try command.execute(directory: directory, run: { _ in try settings(directory: directory, platform: "iphoneos") },
                    build: { _, log in
                        try Data("error: cannot find 'x' in scope\n".utf8).write(to: log)
                        throw CommandFailure(description: "Xcode build failed (65); raw build log: \(log.path)")
                    })
            } throws: { String(describing: $0) == "Xcode build failed (65); raw build log: \(directory.appendingPathComponent("build.log").path)" }
        }
    }

    @Test func unresolvableCoreDeviceUUIDStopsBeforeXcode() async throws {
        let service = CommandService(readinessQuery: { _ in throw CommandFailure(description: "fixture details unavailable") })
        await #expect {
            try await service.run(["build-run", "nonexistent.xcodeproj", "NoApp", "--device", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])
        } throws: { String(describing: $0).contains("Pass the device's hardware UDID") }
    }

    @Test func dryRunShowsProvisioningEffectAndDeploymentOrder() async throws {
        let service = CommandService()
        let base = ["build-run", "A.xcworkspace", "A", "--device", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]
        let plain = try #require(try JSONSerialization.jsonObject(with: await service.run(base, dryRun: true).data) as? [String: Any])
        let plainBuild = try #require(plain["buildArguments"] as? [String])
        #expect(!plainBuild.contains("-allowProvisioningUpdates"))
        let plainProvisioning = try #require(plain["provisioning"] as? [String: Any])
        #expect(plainProvisioning["allowProvisioningUpdates"] as? Bool == false)
        #expect((plainProvisioning["effect"] as? String)?.contains("not contacted") == true)
        #expect(plain["destinationResolution"] is String)
        #expect(plain["launchArguments"] as? [String] == ["devicectl", "device", "process", "launch", "--terminate-existing",
            "--device", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "--timeout", "60", "--json-output", "-", "<PRODUCT_BUNDLE_IDENTIFIER>"])
        #expect((plain["installArguments"] as? [String])?.prefix(5) == ["devicectl", "device", "install", "app", "<TARGET_BUILD_DIR>/<FULL_PRODUCT_NAME>"])

        let flagged = try #require(try JSONSerialization.jsonObject(with: await service.run(
            base + ["--allow-provisioning-updates", "--allow-device-registration"], dryRun: true).data) as? [String: Any])
        let build = try #require(flagged["buildArguments"] as? [String])
        #expect(build.suffix(3) == ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"])
        #expect((flagged["buildSettingsArguments"] as? [String])?.contains("-allowProvisioningUpdates") == false)
        let provisioning = try #require(flagged["provisioning"] as? [String: Any])
        #expect(provisioning["allowDeviceRegistration"] as? Bool == true)
        #expect((provisioning["effect"] as? String)?.contains("register this device") == true)

        let simulator = try #require(try JSONSerialization.jsonObject(with: await service.run(
            ["build-run", "A.xcodeproj", "A", "--simulator", device], dryRun: true).data) as? [String: Any])
        #expect(simulator["provisioning"] == nil)
        #expect(simulator["destinationResolution"] == nil)
        await #expect(throws: CommandFailure.self) {
            try await service.run(["build-run", "A.xcodeproj", "A", "--allow-provisioning-updates", "--simulator", device], dryRun: true)
        }
    }

    @Test func ambiguousOrWrongPlatformProductsAreRejected() throws {
        let command = try request()
        let directory = URL(fileURLWithPath: "/project/tmp/build")
        for data in [try settings(directory: directory, targets: []),
                     try settings(directory: directory, targets: ["One", "Two"]),
                     try settings(directory: directory, platform: "iphoneos")] {
            #expect(throws: CommandFailure.self) { try command.product(settings: data) }
        }
        let selected = try request(appTarget: "Two")
        let product = try selected.product(settings: settings(directory: directory, targets: ["One", "Two"]))
        #expect(product.bundleID == "org.example.build-run")
    }

    @Test func pipelineBuildsThenInstallsAndLaunchesSelectedApp() throws {
        try fixture { directory in
            var events: [String] = []
            let command = try request()
            let result = try command.execute(directory: directory, run: { plan in
                if plan.arguments.contains("-showBuildSettings") {
                    events.append("settings")
                    return try settings(directory: directory)
                }
                events.append(plan.arguments[1])
                if plan.arguments[1] == "install" {
                    #expect(plan.arguments == ["simctl", "install", device, directory.appendingPathComponent("My App.app").path])
                } else {
                    #expect(plan.arguments == ["simctl", "launch", "--terminate-running-process", device, "org.example.build-run"])
                }
                return Data("org.example.build-run: 123\n".utf8)
            }, build: { args, log in
                events.append("build")
                #expect(args.last == "build")
                #expect(log.lastPathComponent == "build.log")
                try writeApp(directory)
            })
            #expect(events == ["settings", "build", "install", "launch"])
            let json = try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])
            #expect(json["status"] as? String == "launched")
            #expect(json["verified"] as? Bool == false)
        }
    }

    @Test func failedBuildNeverDeploysEvenIfAnOldAppExists() throws {
        try fixture { directory in
            try writeApp(directory)
            var runCount = 0
            #expect(throws: CommandFailure.self) {
                try request().execute(directory: directory, run: { _ in
                    runCount += 1
                    return try settings(directory: directory)
                }, build: { _, _ in throw CommandFailure(description: "fixture build failed") })
            }
            #expect(runCount == 1)
        }
    }

    @Test func mismatchedBuiltAppNeverDeploys() throws {
        try fixture { directory in
            var runCount = 0
            #expect(throws: CommandFailure.self) {
                try request().execute(directory: directory, run: { _ in
                    runCount += 1
                    return try settings(directory: directory)
                }, build: { _, _ in try writeApp(directory, bundle: "org.example.wrong") })
            }
            #expect(runCount == 1)
        }
    }

    @Test func failedInstallNeverLaunches() throws {
        try fixture { directory in
            var operations: [String] = []
            #expect(throws: CommandFailure.self) {
                try request().execute(directory: directory, run: { plan in
                    if plan.arguments.contains("-showBuildSettings") { return try settings(directory: directory) }
                    operations.append(plan.arguments[1])
                    throw CommandFailure(description: "fixture install failed")
                }, build: { _, _ in try writeApp(directory) })
            }
            #expect(operations == ["install"])
        }
    }

    @Test func physicalDeploymentUsesCoreDeviceAndRestartsExistingApp() throws {
        try fixture { directory in
            let command = try Self.physical(project: "App.xcodeproj", scheme: "App")
            var operations: [[String]] = []
            _ = try command.execute(directory: directory, run: { plan in
                if plan.arguments.contains("-showBuildSettings") {
                    #expect(plan.arguments.contains("id=00000000-0000000000000000"))
                    return try settings(directory: directory, platform: "iphoneos")
                }
                operations.append(plan.arguments)
                return Data("{\"info\":{\"outcome\":\"success\"}}".utf8)
            }, build: { _, _ in
                try writeApp(directory)
                let infoURL = directory.appendingPathComponent("My App.app/Info.plist")
                var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
                info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            })
            #expect(operations.count == 2)
            #expect(operations.first?.prefix(4) == ["devicectl", "device", "install", "app"])
            #expect(operations.last == ["devicectl", "device", "process", "launch", "--terminate-existing",
                "--device", "00000000-0000000000000000", "--timeout", "60", "--json-output", "-", "org.example.build-run"])
        }
    }
}

/// `--build-timeout` and the progress lines on stderr.
struct BuildRunDeadlineTests {
    let device = "11111111-2222-3333-4444-555555555555"

    @Test func theProgressLineNamesTheTimeTheStepsAndTheLatest() {
        let log = Data("""
        Prepare packages
        ComputeTargetDependencyGraph
        SwiftDriver ProbeTV normal arm64 com.apple.xcode.tools.swift.compiler (in target 'ProbeTV' from project 'ProbeApp')
            cd /work/Fixtures
        SwiftCompile normal arm64 /work/Fixtures/ProbeApp/TV/ProbeTVVideo.swift (in target 'ProbeTV' from project 'ProbeApp')
        note: a note that is not a step
        """.utf8)
        #expect(BuildRunCommand.progressLine(log: log, elapsed: 40.7) == "build-run: 40 s, 2 steps, now SwiftCompile ProbeTVVideo.swift")
        #expect(BuildRunCommand.progressLine(log: Data("Prepare packages\n".utf8), elapsed: 10) == "build-run: 10 s, 0 steps, xcodebuild preparing")
    }

    @Test func theDeadlineIsCheckedBeforeAnyBuildAndReachesMCP() throws {
        let built = try BuildRunCommand(physical: false, device: device, project: "A.xcodeproj", scheme: "A", configuration: nil, appTarget: nil, buildTimeout: "600")
        #expect(built.buildTimeoutSeconds == 600)
        for value in ["29", "7201", "ten", "1.5"] {
            let failure = #expect(throws: CommandFailure.self) {
                try BuildRunCommand(physical: false, device: device, project: "A.xcodeproj", scheme: "A", configuration: nil, appTarget: nil, buildTimeout: value)
            }
            #expect(failure?.code == .usage)
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "build_run" })
        let args = try tool.command(["device": .string(device), "platform": "simulator", "project": "A.xcodeproj", "scheme": "A", "build_timeout_seconds": 600])
        guard case .buildRun(let request) = try CLI.invocation(args).request else {
            Issue.record("Not a build-run request: \(args)"); return
        }
        #expect(request.buildTimeoutSeconds == 600)
    }

    /// A build past its deadline is stopped, the log so far is kept, and
    /// the progress reports saw it while it ran. Nothing reached a device.
    @Test(.dedicatedThread, .timeLimit(.minutes(1))) func aBuildPastItsDeadlineIsStoppedWithItsLogKept() throws {
        let directory = URL(fileURLWithPath: "tmp/build-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("build.log")
        let reports = Mutex<[String]>([])
        let failure = #expect(throws: CommandFailure.self) {
            try ToolRunner().build(["-c", "echo 'SwiftCompile normal arm64 /work/A.swift'; sleep 20"], log: log, executable: "/bin/sh",
                                   timeout: 1, progressInterval: 0.2) { data, elapsed in
                reports.withLock { $0.append(BuildRunCommand.progressLine(log: data, elapsed: elapsed)) }
            }
        }
        #expect(failure?.code == .timeout && failure?.inputSent == CommandFailure.InputSent.none)
        #expect(failure?.description.contains(log.path) == true)
        #expect((try? String(contentsOf: log, encoding: .utf8))?.contains("SwiftCompile") == true)
        #expect(reports.withLock { $0.contains { $0.hasSuffix("now SwiftCompile A.swift") } })
    }
}
