import Foundation
import Testing
@testable import Manzanero

struct DeviceCommandsTests {
    let simulator = "1DCC0F91-CF8C-4774-BD9C-BC94AF982632"

    @Test func physicalLaunchKeepsAllDevicectlOptionsBeforeAppArgument() throws {
        let plan = try DeviceCommand.plan(physical: true, device: "fixture-phone", operation: "launch", operands: ["com.apple.Preferences"])
        #expect(plan.arguments == ["devicectl", "device", "process", "launch", "--device", "fixture-phone",
            "--timeout", "60", "--json-output", "-", "com.apple.Preferences"])
        #expect(plan.jsonOutput)
    }

    @Test func rebootPlansDevicectlForADeviceAndSimctlForASimulator() async throws {
        let device = "00008110-000A11112222801E"
        let physical = try DeviceCommand.plan(physical: true, device: device, operation: "reboot")
        #expect(physical.arguments == ["devicectl", "device", "reboot", "--device", device, "--timeout", "180", "--json-output", "-"])
        #expect(physical.jsonOutput)
        let simulated = try DeviceCommand.plan(physical: false, device: simulator, operation: "reboot")
        #expect(simulated.arguments == ["simctl", "reboot", simulator] && !simulated.jsonOutput)
        #expect(throws: CommandFailure.self) { try DeviceCommand.plan(physical: true, device: device, operation: "reboot", operands: ["now"]) }

        #expect(summary(try request(["reboot", "--device", device])) == ["physical", device, "reboot"])
        #expect(summary(try request(["reboot", "--simulator", simulator])) == ["simulator", simulator, "reboot"])
        let rebooting = try request(["reboot", "--simulator", simulator])
        #expect(!rebooting.isReadOnly && rebooting.addressed?.operation == "reboot")

        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let plan = try #require(try JSONSerialization.jsonObject(with: await service.run(["reboot", "--device", device], dryRun: true).data) as? [String: Any])
        #expect(plan["arguments"] as? [String] == physical.arguments)

        let tool = try #require(MCPTools.definitions.first { $0.name == "reboot_device" })
        #expect(try tool.command(["platform": .string("physical"), "device": .string(device)]) == ["reboot", "--device=\(device)"])
        #expect(try tool.command(["platform": .string("simulator"), "device": .string(simulator)]) == ["reboot", "--simulator=\(simulator)"])
        #expect(!tool.readOnly)
    }

    @Test func launchOptionsReachDevicectlAndSimctl() throws {
        let options = try LaunchOptions(arguments: ["-ProbeList", "YES"], environment: ["A=1", "B=x=y"], language: "pt-BR", locale: "es_ES", relaunch: true)
        let physical = try DeviceCommand.launch(physical: true, device: "fixture-phone", bundle: "com.example.app", options: options)
        #expect(physical.arguments == ["devicectl", "device", "process", "launch", "--device", "fixture-phone", "--terminate-existing",
            "--environment-variables", #"{"A":"1","B":"x=y"}"#, "--timeout", "60", "--json-output", "-", "--", "com.example.app",
            "-AppleLanguages", "(pt-BR)", "-AppleLocale", "es_ES", "-ProbeList", "YES"])
        #expect(physical.environment.isEmpty)
        let simulated = try DeviceCommand.launch(physical: false, device: simulator, bundle: "com.example.app", options: options)
        #expect(simulated.arguments == ["simctl", "launch", "--terminate-running-process", simulator, "com.example.app",
            "-AppleLanguages", "(pt-BR)", "-AppleLocale", "es_ES", "-ProbeList", "YES"])
        #expect(simulated.environment == ["SIMCTL_CHILD_A": "1", "SIMCTL_CHILD_B": "x=y"])
        // Without options, launch plans exactly as before.
        #expect(try DeviceCommand.launch(physical: true, device: "fixture-phone", bundle: "com.apple.Preferences", options: LaunchOptions())
            == DeviceCommand.plan(physical: true, device: "fixture-phone", operation: "launch", operands: ["com.apple.Preferences"]))
    }

    @Test(arguments: [(["=1"], nil, nil), (["1A=2"], nil, nil), (["A"], nil, nil), (["A=1", "A=2"], nil, nil),
                      ([], "e", nil), ([], "es_ES", nil), ([], nil, "es-ES"), ([], nil, "es_")] as [([String], String?, String?)])
    func invalidLaunchOptionsAreUsageErrors(_ environment: [String], _ language: String?, _ locale: String?) {
        #expect(throws: CommandFailure.self) { try LaunchOptions(environment: environment, language: language, locale: locale) }
    }

    @Test func launchCommandParsesItsOptions() throws {
        let parsed = try request(["launch", "com.example.app", "--device", "fixture-phone", "--env", "A=1", "--language", "es", "--relaunch", "--", "-x", "--y"])
        guard case .tool(let tool) = parsed else { Issue.record("launch is not a tool request"); return }
        #expect(tool.command == (try DeviceCommand.launch(physical: true, device: "fixture-phone", bundle: "com.example.app",
            options: LaunchOptions(arguments: ["-x", "--y"], environment: ["A=1"], language: "es", relaunch: true))))
    }

    @Test func physicalTerminateByBundleResolvesItsOneProcess() throws {
        let tool = try DeviceOperation(Target(platform: .physical, identifier: "fixture-phone"), "terminate", ["com.example.app"])
        #expect(tool.bundleToResolve == "com.example.app")
        #expect(tool.command.arguments.contains(DeviceCommand.resolvedPIDPlaceholder))
        let byPID = try DeviceOperation(Target(platform: .physical, identifier: "fixture-phone"), "terminate", ["42"])
        #expect(byPID.bundleToResolve == nil)
        let onSimulator = try DeviceOperation(Target(platform: .simulator, identifier: simulator), "terminate", ["com.example.app"])
        #expect(onSimulator.bundleToResolve == nil && onSimulator.command.arguments == ["simctl", "terminate", simulator, "com.example.app"])
        #expect(throws: CommandFailure.self) { try DeviceOperation(Target(platform: .physical, identifier: "fixture-phone"), "terminate", ["0"]) }

        let apps = Data(#"{"result":{"apps":[{"bundleIdentifier":"com.example.app","url":"file:///private/var/containers/Bundle/Application/X/App.app/"}]}}"#.utf8)
        func processes(_ paths: [(Int, String)]) -> Data {
            let list = paths.map { #"{"processIdentifier":\#($0.0),"executable":"file://\#($0.1)"}"# }.joined(separator: ",")
            return Data(#"{"result":{"runningProcesses":[\#(list)]}}"#.utf8)
        }
        let main = "/var/containers/Bundle/Application/X/App.app/App"
        let widget = "/var/containers/Bundle/Application/X/App.app/PlugIns/W.appex/W"
        #expect(try RunningApp.pid(of: "com.example.app", apps: apps, processes: processes([(7, "/usr/libexec/x"), (42, main), (43, widget)])) == 42)
        let none = try #require(throws: CommandFailure.self) { try RunningApp.pid(of: "com.example.app", apps: apps, processes: processes([(43, widget)])) }
        #expect(none.description.contains("is not running") && none.inputSent == .none)
        let two = try #require(throws: CommandFailure.self) { try RunningApp.pid(of: "com.example.app", apps: apps, processes: processes([(42, main), (44, main)])) }
        #expect(two.description.contains("PIDs 42, 44"))
        #expect(throws: CommandFailure.self) { try RunningApp.pid(of: "com.other.app", apps: apps, processes: processes([(42, main)])) }
    }

    func failure(_ args: [String], dryRun: Bool) async -> String? {
        await commandFailure(args, dryRun: dryRun).map { String(describing: $0) }
    }

    func commandFailure(_ args: [String], dryRun: Bool) async -> (any Error)? {
        let service = CommandService(readinessQuery: { _ in Issue.record("Removed route queried a device"); return Data() })
        do {
            _ = try await service.run(args, dryRun: dryRun)
            return nil
        } catch {
            return error
        }
    }

    /// Each command with the target inserted after the operation name.
    @Test(arguments: [["tap", "10", "10"], ["tap", "--", "--help", "0.5"], ["swipe", "0", "0", "10", "10", "1"],
                      ["drag", "0", "0", "10", "10", "1"], ["tree", "--pid", "0"], ["press", "--id", ""],
                      ["type", "a→b"], ["button", "power"], ["key", "f1"]])
    func invalidSimulatorInputFailsAsUsageWithoutAPlan(_ command: [String]) async throws {
        func targeted(_ simulator: String) -> [String] { [command[0], "--simulator", simulator] + command.dropFirst() }
        for dryRun in [false, true] {
            let message = try #require(await failure(targeted(simulator), dryRun: dryRun))
            #expect(!message.lowercased().contains("axe") && !message.contains("not available"))
            let alias = try #require(await failure(targeted("booted"), dryRun: dryRun))
            #expect(alias.contains("requires the simulator's UUID"))
        }
    }

    /// Removed operations are not commands: the parser refuses them as usage errors.
    @Test(arguments: [["hid-info"], ["ax-snapshot"], ["ax-snapshot", "tmp/fixture.plist"]])
    func removedPhysicalObservationsAreUnknownCommands(_ operands: [String]) async throws {
        for dryRun in [false, true] {
            let error = try #require(await commandFailure(operands + ["--device", "fixture"], dryRun: dryRun) as? CommandFailure)
            #expect(error.code == .usage && error.inputSent == .none)
        }
    }

    // The retired helper's `physical <UDID> logs <seconds> [pid]` form is not
    // in the grammar (logs takes options only).
    @Test(arguments: [["logs", "30"], ["logs", "1", "123"]])
    func physicalLogsOperandsAreUsageErrors(_ command: [String]) async throws {
        for dryRun in [false, true] {
            let error = try #require(await commandFailure(command + ["--device", "fixture"], dryRun: dryRun) as? CommandFailure)
            #expect(error.code == .usage && error.inputSent == .none)
        }
    }

    @Test func physicalLogsPlanTheRelayAndStreamOnly() async throws {
        let output = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried a device"); return Data() })
            .run(["logs", "--seconds", "5", "--bundle", "com.example.probe", "--level", "debug", "--device", "fixture"], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["backend"] as? String == "os-trace-relay" && plan["platform"] as? String == "physical")
        #expect(plan["service"] as? String == OSTraceRelay.service && plan["readOnly"] as? Bool == true)
        #expect((plan["targetResolution"] as? [String: Any])?["bundles"] as? [String] == ["com.example.probe"])
        for stored in [["--last", "30"], ["--start", "2026-11-20T10:00:00Z"]] {
            await #expect { _ = try await CommandService().run(["logs"] + stored + ["--pid", "1", "--device", "fixture"], dryRun: true) } throws: {
                ($0 as? CommandFailure)?.code == .usage && ($0 as? CommandFailure)?.description.contains("--seconds") == true
            }
        }
    }

    @Test func pairingCommandsAreNoLongerRecognised() async throws {
        for args in [["pair", "wifi", "phone.local", "1234", "tmp/phone.pairing.plist"],
                     ["--pairing-file", "tmp/phone.pairing.plist", "tap", "0", "1", "--device", "fixture"]] {
            for dryRun in [false, true] {
                let error = try #require(await commandFailure(args, dryRun: dryRun) as? CommandFailure)
                #expect(error.code == .usage && error.inputSent == .none, "\(args)")
            }
        }
    }

    @Test func thereIsNoPhysicalBackendOption() async throws {
        for args in [["button", "home", "--physical-backend", "idevice", "--device", "fixture"],
                     ["button", "home", "--physical-backend", "coredevice", "--device", "fixture"]] {
            for dryRun in [false, true] {
                let error = try #require(await commandFailure(args, dryRun: dryRun) as? CommandFailure)
                #expect(error.code == .usage && error.inputSent == .none)
            }
        }
        let input = try #require(try physicalInput(["button", "home", "--device", "fixture"]))
        #expect(input.operation == "button" && input.operands == ["home"])
    }

    @Test func remainingDeviceCommandDryRunsPlanOnlyAppleTools() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        for args in [["apps", "--device", "fixture"], ["screenshot", "tmp/x.png", "--device", "fixture"],
                     ["reports", "list", "--device", "fixture"], ["boot", "--simulator", simulator], ["screenshot", "tmp/x.png", "--simulator", simulator]] {
            let output = try await service.run(args, dryRun: true)
            let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["executable"] as? String == "/usr/bin/xcrun")
            // A simulator screenshot also says how its display is chosen at run time.
            let simulatorCapture = args.first == "screenshot" && args.contains("--simulator")
            #expect(Set(plan.keys) == (simulatorCapture ? ["executable", "arguments", "display"] : ["executable", "arguments"]))
        }
    }
}
