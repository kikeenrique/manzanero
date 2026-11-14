import Foundation
import Testing
@testable import Manzanero

struct BuildRunCommandTests {
    let device = "11111111-2222-3333-4444-555555555555"

    func request(_ extra: [String] = []) throws -> BuildRunCommand {
        try #require(try BuildRunCommand.parse(["simulator", device, "build-run", "tmp/My App.xcodeproj", "My App"] + extra))
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
        let command = try #require(try BuildRunCommand.parse(["simulator", device, "build-run", "tmp/$(touch sentinel).xcworkspace", "My App; echo x", "--configuration", "Custom Debug"]))
        let args = command.xcodeArguments(directory: URL(fileURLWithPath: "/project/tmp/build"))
        #expect(args.prefix(7) == ["xcodebuild", "-workspace", "tmp/$(touch sentinel).xcworkspace", "-scheme", "My App; echo x", "-configuration", "Custom Debug"])
        #expect(args.contains("platform=iOS Simulator,id=\(device)"))
        #expect(args.contains("-allowProvisioningUpdates") == false)
    }

    @Test(arguments: [
        ["simulator", "booted", "build-run", "A.xcodeproj", "A"],
        ["physical", "x,id=other", "build-run", "A.xcodeproj", "A"],
        ["simulator", "11111111-2222-3333-4444-555555555555", "build-run", "A.xcodeproj"],
        ["simulator", "11111111-2222-3333-4444-555555555555", "build-run", "A", "A"],
        ["simulator", "11111111-2222-3333-4444-555555555555", "build-run", "A.xcodeproj", "A", "--unknown", "x"],
        ["simulator", "11111111-2222-3333-4444-555555555555", "build-run", "A.xcodeproj", "A", "--configuration", "Debug", "--configuration", "Release"]
    ]) func invalidRequestsAreRejected(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try BuildRunCommand.parse(args) }
    }

    @Test func ambiguousOrWrongPlatformProductsAreRejected() throws {
        let command = try request()
        let directory = URL(fileURLWithPath: "/project/tmp/build")
        for data in [try settings(directory: directory, targets: []),
                     try settings(directory: directory, targets: ["One", "Two"]),
                     try settings(directory: directory, platform: "iphoneos")] {
            #expect(throws: CommandFailure.self) { try command.product(settings: data) }
        }
        let selected = try request(["--app-target", "Two"])
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
            let command = try #require(try BuildRunCommand.parse(["physical", "00000000-0000000000000000", "build-run", "App.xcodeproj", "App"]))
            var operations: [[String]] = []
            _ = try command.execute(directory: directory, run: { plan in
                if plan.arguments.contains("-showBuildSettings") {
                    #expect(plan.arguments.contains("platform=iOS,id=00000000-0000000000000000"))
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
