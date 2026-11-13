import AppleDeviceBridge
import Darwin
import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilitySocketTests {
    @Test func invalidIdentityNeverOpensAndClearsOwner() {
        for (uuid, version) in [("invalid", "651.32"), (UUID().uuidString, "bad"), (UUID().uuidString, "1.2.3.4.5"), (UUID().uuidString, "1\n")] {
            var owner: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: 1)
            var error = [CChar](repeating: 0, count: 512)
            #expect(ADCOpenAccessibilitySocket(uuid, version, &owner, &error, error.count) == -1)
            #expect(owner == nil)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("Invalid direct accessibility"))
        }
        var owner: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: 1)
        var error = [CChar](repeating: 0, count: 512)
        #expect(ADCOpenRSDAccessibilitySocket("invalid", "invalid", &owner, &error, error.count) == -1)
        #expect(owner == nil)
        #expect(ADCOpenBrowsedRSDAccessibilitySocket("invalid", "invalid", &owner, &error, error.count) == -1)
        #expect(owner == nil)
        #expect(ADCOpenRSDAccessibilitySocket(UUID().uuidString, "00000000-0000000000000000\n", &owner, &error, error.count) == -1)
        #expect(owner == nil)
        ADCCloseAccessibilitySocket(-1, nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_AX_SOCKET_DEVICE"] != nil))
    func liveAppleSocketOpensWithoutStartingAccessibilitySubscription() throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_AX_SOCKET_DEVICE"])
        let input = CoreDeviceInput(device: device, operation: "ax-snapshot", operands: [])
        let identity = try DirectPhysicalInput.identity(input, query: { plan in
            try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 40)
        })
        var owner: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 1024)
        let descriptor: Int32
        if let remote = ProcessInfo.processInfo.environment["APPLEDEVICES_AX_SOCKET_REMOTE_UUID"] {
            descriptor = ProcessInfo.processInfo.environment["APPLEDEVICES_AX_SOCKET_BROWSE"] == "1" ?
                ADCOpenBrowsedRSDAccessibilitySocket(remote, device, &owner, &error, error.count) :
                ADCOpenRSDAccessibilitySocket(remote, device, &owner, &error, error.count)
        } else {
            descriptor = ADCOpenAccessibilitySocket(identity.uuid, identity.version, &owner, &error, error.count)
        }
        let description = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard descriptor >= 0 else { throw CommandFailure(description: description) }
        defer { ADCCloseAccessibilitySocket(descriptor, owner) }
        #expect(owner != nil)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        // Opening an FD alone does not verify DTX negotiation or a tree.
    }
}
