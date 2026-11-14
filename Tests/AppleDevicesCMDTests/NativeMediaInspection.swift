import AppleDeviceBridge
import Foundation
import Testing
import XPC
@testable import AppleDevicesCMD

struct NativeMediaInspectionTests {
    private func replies() -> (xpc_object_t, xpc_object_t) {
        let support = xpc_dictionary_create(nil, nil, 0), capabilities = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(capabilities, "supportedFeatures", 972)
        xpc_dictionary_set_string(capabilities, "avcFrameworkVersion", "2235.63.1.2")
        xpc_dictionary_set_value(support, "CoreDevice.output", capabilities)
        let status = xpc_dictionary_create(nil, nil, 0), output = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(output, "running", false)
        xpc_dictionary_set_double(output, "runDurationSeconds", 0)
        xpc_dictionary_set_value(output, "sessions", xpc_array_create(nil, 0))
        xpc_dictionary_set_value(status, "CoreDevice.output", output)
        return (support, status)
    }

    @Test func inspectionRequiresTypedBoundedRepliesAndDoesNotExportSessionValues() throws {
        let (support, status) = replies()
        var value = ADCMediaInspection(), error = [CChar](repeating: 0, count: 512)
        func validate(_ support: xpc_object_t?, _ status: xpc_object_t?) -> Int32 {
            value.supportedFeatures = 123; value.sessionCount = 999; value.running = 9
            return ADCValidateMediaInspection(support.map { Unmanaged.passUnretained($0).toOpaque() },
                status.map { Unmanaged.passUnretained($0).toOpaque() }, &value, &error, error.count)
        }
        #expect(validate(support, status) == 0)
        #expect(value.supportedFeatures == 972 && value.running == 0 && value.sessionCount == 0)
        let version = withUnsafeBytes(of: value.avcVersion) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #expect(version == "2235.63.1.2")
        let output = try #require(xpc_dictionary_get_dictionary(status, "CoreDevice.output"))
        let sessions = xpc_array_create(nil, 0)
        xpc_array_append_value(sessions, xpc_string_create("opaque-session-not-exported"))
        xpc_dictionary_set_value(output, "sessions", sessions)
        xpc_dictionary_set_bool(output, "running", true)
        xpc_dictionary_set_double(output, "runDurationSeconds", 2.5)
        #expect(validate(support, status) == 0)
        #expect(value.running == 1 && value.sessionCount == 1 && value.runDurationSeconds == 2.5)
        for failure in ["nil", "wrong-root", "error", "flags-bool", "version-size", "version-shape", "running-int", "sessions-size", "duration-nan", "duration-negative"] {
            let (support, status) = replies()
            let capabilities = try #require(xpc_dictionary_get_dictionary(support, "CoreDevice.output"))
            let output = try #require(xpc_dictionary_get_dictionary(status, "CoreDevice.output"))
            switch failure {
            case "error": xpc_dictionary_set_value(status, "CoreDevice.error", xpc_dictionary_create(nil, nil, 0))
            case "flags-bool": xpc_dictionary_set_bool(capabilities, "supportedFeatures", true)
            case "version-size": xpc_dictionary_set_string(capabilities, "avcFrameworkVersion", String(repeating: "1", count: 128))
            case "version-shape": xpc_dictionary_set_string(capabilities, "avcFrameworkVersion", "1..2")
            case "running-int": xpc_dictionary_set_int64(output, "running", 1)
            case "sessions-size":
                let array = xpc_array_create(nil, 0)
                for _ in 0..<129 { xpc_array_append_value(array, xpc_null_create()) }
                xpc_dictionary_set_value(output, "sessions", array)
            case "duration-nan": xpc_dictionary_set_double(output, "runDurationSeconds", .nan)
            case "duration-negative": xpc_dictionary_set_double(output, "runDurationSeconds", -1)
            default: break
            }
            #expect(validate(failure == "nil" ? nil : failure == "wrong-root" ? xpc_string_create("wrong") : support, status) != 0)
            #expect(value.supportedFeatures == 0 && value.running == 0 && value.sessionCount == 0)
        }
    }

    @Test func invalidAndPreCancelledTargetsClearOutputBeforeFrameworkAccess() {
        for (uuid, version, cancel) in [("alias", "651.32", false), (UUID().uuidString, "bad-version", false), (UUID().uuidString, "651.32", true)] {
            var result = ADCMediaInspection(), error = [CChar](repeating: 0, count: 512)
            result.running = 9; result.supportedFeatures = 99
            #expect(ADCInspectMedia(uuid, version, { cancel ? 1 : 0 }, &result, &error, error.count) != 0)
            #expect(result.running == 0 && result.supportedFeatures == 0)
        }
    }

    @Test func sharedCLIAndMCPDryRunsDoNotQueryOrClaimCapture() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried"); return Data() })
        let result = try await service.execute(["physical", "fixture", "media-status"], dryRun: true)
        let value = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect(value["readOnly"] as? Bool == true && value["operation"] as? String == "media-status")
        let tool = try #require(MCPTools.definitions.first { $0.name == "inspect_device" })
        #expect(tool.readOnly)
        #expect(try tool.command(["platform": "physical", "device": "fixture", "query": "media-status"]) == ["physical", "fixture", "media-status"])
        #expect(throws: CommandFailure.self) { try NativeMediaInspection.parse(["physical", "fixture", "media-status", "stop"]) }
        let disabled = try DeviceReadinessTests().fixture(mode: "disabled")
        #expect(throws: CommandFailure.self) { try NativeMediaInspection.execute(device: "fixture", query: { _ in disabled }) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_INSPECTION_DEVICE"] != nil))
    func explicitLiveInspectionReadsCapabilitiesAndStatusWithoutStartingOrStopping() throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_INSPECTION_DEVICE"])
        let bytes = try NativeMediaInspection.execute(device: device, query: { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) })
        let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(root["streamMutationRequested"] as? Bool == false)
        #expect(root["sessionCount"] as? Int != nil && root["running"] as? Bool != nil)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/media-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent("result.json").path, contents: bytes, attributes: [.posixPermissions: 0o600]))
    }
}
