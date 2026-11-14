import Foundation
import Testing
import MCP
@testable import Manzanero

struct DeviceReadinessTests {
    func fixture(mode: Any?, ddi: Bool? = false, legacyMode: String? = nil) throws -> Data {
        var state: [String: Any] = [:], legacy: [String: Any] = [:]
        if let mode { state["developerModeStatus"] = mode }
        if let ddi { legacy["ddiServicesAvailable"] = ddi }
        if let legacyMode { legacy["developerModeStatus"] = legacyMode }
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": [
            "properties": ["state": state, "connection": ["state": "connected", "pairingState": "paired"]], "deviceProperties": legacy]])
    }

    @Test func disabledModeProvidesPhoneStepsAndReportsMissingDeveloperImage() throws {
        let report = try DeviceReadiness.decode(fixture(mode: ["disabled": [:]]), device: "fixture")
        #expect(report.developerMode == "disabled")
        #expect(report.developerDiskImageServices == "unavailable")
        #expect(report.status == "blocked")
        #expect(report.issues.contains { $0.code == "developerModeDisabled" && $0.action.contains("restart") })
        #expect(try report.output().exitCode == 1)
        #expect(throws: CommandFailure.self) { try report.requireDeveloperMode(operation: "tap") }
    }

    @Test func currentPropertiesTakePrecedenceOverDeprecatedFields() throws {
        let report = try DeviceReadiness.decode(fixture(mode: ["disabled": [:]], ddi: true, legacyMode: "enabled"), device: "fixture")
        #expect(report.developerMode == "disabled")
        let enabled = try DeviceReadiness.decode(fixture(mode: ["enabled": [:]], ddi: true), device: "fixture")
        #expect(enabled.status == "prerequisitesPresent")
        #expect(try enabled.output().exitCode == 0)
        #expect(!enabled.limitations.isEmpty)
    }

    @Test func unknownOrPartialMetadataNeverReportsPrerequisitesPresent() throws {
        for mode: Any? in [nil, ["futureState": [:]], ["disabled": [:], "enabled": [:]]] {
            let report = try DeviceReadiness.decode(fixture(mode: mode, ddi: true, legacyMode: mode == nil ? nil : "enabled"), device: "fixture")
            #expect(report.developerMode == "unknown")
            #expect(report.status == "unknown")
            #expect(try report.output().exitCode == 1)
        }
        let unknownImage = try DeviceReadiness.decode(fixture(mode: "enabled", ddi: nil), device: "fixture")
        #expect(unknownImage.developerDiskImageServices == "unknown")
        #expect(unknownImage.status == "unknown")
    }

    @Test func legacyModeIsUsedWhenCurrentFieldIsAbsent() throws {
        let report = try DeviceReadiness.decode(fixture(mode: nil, ddi: true, legacyMode: "enabled"), device: "fixture")
        #expect(report.developerMode == "enabled")
        #expect(report.status == "prerequisitesPresent")
    }

    @Test func failedDetailsResultCannotBecomeReadiness() {
        #expect(throws: CommandFailure.self) { try DeviceReadiness.decode(Data("{\"info\":{\"outcome\":\"failed\"},\"result\":{}}".utf8), device: "fixture") }
    }

    @Test func disabledPreflightStopsRecordingAndBuildBeforeSideEffects() async throws {
        let data = try fixture(mode: ["disabled": [:]])
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.execute(["physical", "fixture", "record", "tmp/blocked.mp4", "1"])
            Issue.record("Disabled device reached recording")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
        do {
            _ = try await service.execute(["physical", "00000000-0000000000000000", "build-run", "nonexistent.xcodeproj", "NoApp"])
            Issue.record("Disabled device reached build")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
        let output = try await service.execute(["physical", "fixture", "readiness"])
        #expect(output.exitCode == 1)
        do {
            _ = try await service.execute(["physical", "fixture", "screen"])
            Issue.record("Disabled device reached screen capture")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
        do {
            _ = try await service.execute(["physical", "fixture", "type", "fixture"])
            Issue.record("Disabled device reached physical typing")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
        for operands in [["pinch", "0.5", "0.5", "0.5", "1", "1"], ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "0"]] {
            do {
                _ = try await service.execute(["physical", "fixture"] + operands)
                Issue.record("Disabled device reached moving multitouch")
            } catch {
                #expect(String(describing: error).contains("Developer Mode is disabled"))
            }
        }
    }

    @Test func mcpReadinessPreservesActionableBlockedState() async throws {
        let data = try fixture(mode: ["disabled": [:]])
        let service = CommandService(readinessQuery: { _ in data })
        let output = try await MCPTools.call(name: "device_readiness", arguments: ["device": "fixture"]) {
            try await service.execute($0)
        }
        #expect(output.isError == true)
        let report = try #require(output.structuredContent?.objectValue?["result"]?.objectValue)
        #expect(report["developerMode"] == "disabled")
        #expect(report["status"] == "blocked")
        #expect(report["issues"]?.arrayValue?.isEmpty == false)
    }
}
