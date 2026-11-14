import AppleDeviceBridge
import Foundation
import ImageIO
import Testing
import XPC
@testable import Manzanero

struct NativeMediaFramesTests {
    @Test(arguments: ["valid", "equivalent-ip", "swapped", "port", "source", "boolean", "oversized", "error", "missing"])
    func negotiatedEndpointsMustMatchOwnedReceiver(mutation: String) {
        let reply = xpc_dictionary_create(nil, nil, 0), output = xpc_dictionary_create(nil, nil, 0)
        let connection = xpc_dictionary_create(nil, nil, 0), config = xpc_dictionary_create(nil, nil, 0)
        let sender = xpc_dictionary_create(nil, nil, 0), receiver = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(sender, "ipv6Address", mutation == "equivalent-ip" ? "fd00:0000:0:0:0:0:0:2" : "fd00::2")
        xpc_dictionary_set_string(receiver, "ipv6Address", "fd00::1")
        xpc_dictionary_set_uint64(sender, "port", 51000)
        xpc_dictionary_set_uint64(receiver, "port", 50000)
        xpc_dictionary_set_uint64(config, "SourcePort", 51000)
        xpc_dictionary_set_value(connection, "sender", sender)
        xpc_dictionary_set_value(connection, "receiver", receiver)
        xpc_dictionary_set_value(connection, "streamConfig", config)
        xpc_dictionary_set_value(output, "connection", connection)
        xpc_dictionary_set_value(reply, "CoreDevice.output", output)
        switch mutation {
        case "swapped": xpc_dictionary_set_string(sender, "ipv6Address", "fd00::1")
        case "port": xpc_dictionary_set_uint64(receiver, "port", 50001)
        case "source": xpc_dictionary_set_uint64(config, "SourcePort", 51001)
        case "boolean": xpc_dictionary_set_bool(sender, "port", true)
        case "oversized": xpc_dictionary_set_uint64(sender, "port", 65536)
        case "error": xpc_dictionary_set_value(reply, "CoreDevice.error", xpc_dictionary_create(nil, nil, 0))
        case "missing": xpc_dictionary_set_value(connection, "sender", nil)
        default: break
        }
        var port: UInt16 = 99, error = [CChar](repeating: 0, count: 512)
        let status = ADCValidateVideoEndpoints(Unmanaged.passUnretained(reply).toOpaque(), "fd00::1", "fd00::2", 50000, &port, &error, error.count)
        let valid = mutation == "valid" || mutation == "equivalent-ip"
        #expect((status == 0) == valid)
        #expect(port == (valid ? 51000 : 0))
    }

    @Test func invalidAndPreCancelledVideoEndpointsHaveNoOwner() {
        for cancelled in [false, true] {
            var owner = UnsafeMutableRawPointer(bitPattern: 1), error = [CChar](repeating: 0, count: 512)
            #expect(ADCCreateVideoSession("invalid", "651.32", "bad", "invalid", "invalid", { cancelled ? 1 : 0 }, &owner, &error, error.count) != 0)
            #expect(owner == nil)
        }
        var cleanup = ADCVideoCleanup()
        #expect(ADCCloseVideoSession(nil, &cleanup, nil, 0) == 0)
        #expect(cleanup.startAttempted == 0 && cleanup.stopAcknowledged == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_MEDIA_FRAMES_DEVICE"] != nil))
    @MainActor func explicitLivePerSessionOutputCapturesFramesAndStopsOnlyOwnedStream() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_MEDIA_FRAMES_DEVICE"])
        let input = CoreDeviceInput(device: device, operation: "media-status", operands: [])
        let plan = try input.identityPlan()
        let details = try ToolRunner().run(plan.arguments, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        let assertion = try NativeTunnelAssertion(device: device, details: details)
        defer { assertion.close() }
        let inventory = try ToolRunner().run(["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"])
        let endpoint = try NativeMediaEndpoint.resolve(details: details, inventory: inventory, requested: device)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/media-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = ["stage": "local-prepare", "frameCount": 0]
        var frames: NativeMediaFrames?
        func record() throws {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        }
        do {
            frames = try NativeMediaFrames(endpoint: endpoint, version: identity.version)
            let displayPlan = AccessibilityDisplay.plan(device: identity.uuid)
            let display = try DirectTouchDisplay(ToolRunner().run(displayPlan.arguments, timeout: 15))
            metadata["stage"] = "start"
            try frames?.start(displayID: Int64(display.id))
            metadata["stage"] = "frames"
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            var count = 0
            var end: ContinuousClock.Instant?
            while true {
                try Task.checkCancellation()
                if let end, ContinuousClock.now >= end { break }
                guard end != nil || ContinuousClock.now < deadline else { throw CommandFailure(description: "Native frame probe exceeded its twelve-second first-frame budget.") }
                if let frame = try frames?.next() {
                    let image = try #require(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
                    #expect(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
                    if count == 0 {
                        #expect(frame.nanoseconds == 0)
                        #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent("first.jpg").path,
                            contents: frame.jpeg, attributes: [.posixPermissions: 0o600]))
                        end = ContinuousClock.now.advanced(by: .seconds(2))
                    }
                    count += 1
                    metadata["frameCount"] = count
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let cleanup = try #require(frames?.close())
            metadata["cleanup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup))
            let release = assertion.close()
            metadata["assertionRelease"] = release.status
            metadata["outcome"] = "captured"
            try record()
            #expect(count > 0 && cleanup.stopAcknowledged && cleanup.ownedStreamAbsent)
        } catch {
            if let cleanup = frames?.close() { metadata["cleanup"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup)) }
            metadata["outcome"] = "failed"; metadata["error"] = String(describing: error)
            metadata["assertionRelease"] = assertion.close().status
            try? record()
            throw error
        }
    }
}
