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
