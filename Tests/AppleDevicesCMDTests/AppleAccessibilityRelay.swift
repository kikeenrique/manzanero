import Foundation
import Subprocess
import System
import Testing
@testable import AppleDevicesCMD

private struct ObservedDTXFrame: Error {
    let bytes: Data
}

struct AppleAccessibilityRelayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_AX_RELAY_DEVICE"] != nil))
    func readsDTXCapabilitiesThroughAppleToolWithoutSubscription() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_AX_RELAY_DEVICE"])
        let remote = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_AX_RELAY_REMOTE_UUID"])
        _ = try #require(UUID(uuidString: remote))
        let native = CoreDeviceInput(device: device, operation: "ax-snapshot", operands: [])
        _ = try DirectPhysicalInput.identity(native, query: { plan in
            try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
        })
        let identity = try ToolRunner().run(["get-property", "-t", "coredevice-device", remote, "UniqueDeviceID"], executable: "/usr/libexec/remotectl", timeout: 5)
        #expect(String(decoding: identity, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(device) == .orderedSame)
        guard String(decoding: identity, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(device) == .orderedSame else {
            throw CommandFailure(description: "Apple relay hardware identity mismatch; no connection started.")
        }
        let hello = try AccessibilityDTX.invocation("_notifyOfPublishedCapabilities:", argument: [
            "com.apple.private.DTXBlockCompression": NSNumber(value: 0),
            "com.apple.private.DTXConnection": NSNumber(value: 1)
        ] as NSDictionary, identifier: 1, expectsReply: false).encoded()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CommandFailure(description: "Apple accessibility relay handshake timed out; no subscription sent.")
                }
                group.addTask {
                    var options = PlatformOptions()
                    options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(1))]
                    let result = try await Subprocess.run(.path(FilePath("/usr/libexec/remotectl")),
                        arguments: ["netcat", remote, "com.apple.accessibility.axAuditDaemon.remoteAXService"],
                        platformOptions: options, input: .inputWriter, output: .sequence, error: .string(limit: 8192)) { execution in
                        _ = try await execution.standardInputWriter.write(Array(hello))
                        var received = Data()
                        for try await chunk in execution.standardOutput {
                            let data = chunk.withUnsafeBytes { Data($0) }
                            guard data.count <= 65536 - received.count else { throw CommandFailure(description: "AX handshake exceeded 64 KiB; no subscription sent.") }
                            received.append(data)
                            if let decoded = try AccessibilityDTX.decodePrefix(received) {
                                guard decoded.message.kind == .invocation else { throw CommandFailure(description: "Apple AX peer did not send a DTX invocation.") }
                                throw ObservedDTXFrame(bytes: Data(received.prefix(decoded.consumed)))
                            }
                        }
                    }
                    throw CommandFailure(description: "Apple AX relay ended without a DTX frame (\(result.terminationStatus)): \(result.standardError)")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            Issue.record("Expected a captured DTX frame")
        } catch let observed as ObservedDTXFrame {
            let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/apple-ax-dtx-\(UUID().uuidString).bin")
            try observed.bytes.write(to: path)
            #expect(observed.bytes.count >= 48)
        }
    }
}
