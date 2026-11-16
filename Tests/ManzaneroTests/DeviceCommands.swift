import Foundation
import Testing
@testable import Manzanero

struct DeviceCommandsTests {
    let simulator = "1DCC0F91-CF8C-4774-BD9C-BC94AF982632"

    @Test func physicalLaunchKeepsAllDevicectlOptionsBeforeAppArgument() throws {
        let plan = try #require(try DeviceCommand.parse(["physical", "fixture-phone", "launch", "com.apple.Preferences"]))
        #expect(plan.arguments == ["devicectl", "device", "process", "launch", "--device", "fixture-phone",
            "--timeout", "60", "--json-output", "-", "com.apple.Preferences"])
        #expect(plan.jsonOutput)
    }

    func failure(_ args: [String], dryRun: Bool) async -> String? {
        let service = CommandService(readinessQuery: { _ in Issue.record("Removed route queried a device"); return Data() })
        do {
            _ = try await service.execute(args, dryRun: dryRun)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test(arguments: [["tap", "10", "10"], ["tap", "--help"], ["swipe", "0", "0", "10", "10", "1"],
                      ["drag", "0", "0", "10", "10", "1"], ["tree", "0"], ["press-id"],
                      ["type", "mañana"], ["button", "volume-up"], ["key", "f1"]])
    func invalidSimulatorInputFailsAsUsageWithoutAPlan(_ operands: [String]) async throws {
        for dryRun in [false, true] {
            let message = try #require(await failure(["simulator", simulator] + operands, dryRun: dryRun))
            #expect(!message.lowercased().contains("axe") && !message.contains("not available"))
            let alias = try #require(await failure(["simulator", "booted"] + operands, dryRun: dryRun))
            #expect(alias.contains("requires the simulator's UUID"))
        }
    }

    @Test(arguments: [["hid-info"], ["ax-snapshot"], ["ax-snapshot", "tmp/fixture.plist"]])
    func removedPhysicalObservationsAreUnsupportedOperations(_ operands: [String]) async throws {
        for dryRun in [false, true] {
            let message = try #require(await failure(["physical", "fixture"] + operands, dryRun: dryRun))
            #expect(message == "Unsupported physical-device operation: \(operands[0]).")
        }
    }

    // The retired helper's `physical <UDID> logs <seconds> [pid]` form, and any
    // other physical logs call, stays unsupported: there is no native relay yet.
    @Test(arguments: [["logs", "30"], ["logs", "1", "123"], ["logs", "--seconds", "5", "--pid", "1"]])
    func physicalLogsRemainUnsupported(_ operands: [String]) async throws {
        for dryRun in [false, true] {
            await #expect { _ = try await CommandService().execute(["physical", "fixture"] + operands, dryRun: dryRun) } throws: {
                ($0 as? CommandFailure)?.code == .unsupportedOperation && ($0 as? CommandFailure)?.description.contains("os_trace_relay") == true
            }
        }
    }

    @Test func pairingCommandsAreNoLongerRecognised() async throws {
        for args in [["pair", "wifi", "phone.local", "1234", "tmp/phone.pairing.plist"],
                     ["--pairing-file", "tmp/phone.pairing.plist", "physical", "fixture", "tap", "0", "1"]] {
            #expect(try DeviceCommand.parse(args) == nil)
            #expect(await failure(args, dryRun: false) == "Unknown command. Run manzanero --help.")
            #expect(await failure(args, dryRun: true) == "--dry-run requires a physical or simulator command.")
        }
    }

    @Test func onlyTheCoreDevicePhysicalBackendIsAccepted() async throws {
        for args in [["--physical-backend", "idevice", "physical", "fixture", "button", "home"], ["--physical-backend"]] {
            for dryRun in [false, true] {
                let message = try #require(await failure(args, dryRun: dryRun))
                #expect(message.hasPrefix("Unsupported physical backend: "))
                #expect(message.contains("coredevice is the only physical backend"))
            }
        }
        let explicit = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", "fixture", "button", "home"]))
        let implicit = try #require(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(["physical", "fixture", "button", "home"])))
        #expect(explicit.operation == implicit.operation && explicit.operands == implicit.operands)
    }

    @Test func remainingDeviceCommandDryRunsPlanOnlyAppleTools() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        for args in [["physical", "fixture", "apps"], ["physical", "fixture", "screenshot", "tmp/x.png"],
                     ["physical", "fixture", "reports"], ["simulator", simulator, "boot"], ["simulator", simulator, "screenshot", "tmp/x.png"]] {
            let output = try await service.execute(args, dryRun: true)
            let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["executable"] as? String == "/usr/bin/xcrun")
            #expect(Set(plan.keys) == ["executable", "arguments"])
        }
    }
}
