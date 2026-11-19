import AppleDeviceBridge
import Foundation

/// The device's accessibility daemon reached through the Mac's own `remoted`,
/// as Apple's Accessibility Inspector reaches it: Apple's MobileDevice
/// framework is served the daemon's shim service, and this process opens no
/// service directory connection of its own, so the device does not reset the
/// one `remoted` holds (docs/transport.md#the-cost-of-this-route). Experimental:
/// only the opt-in check uses it.
final class AccessibilityShim {
    private var owner: UnsafeMutableRawPointer?
    /// The stream the daemon speaks DTX on. The transport takes ownership.
    let transport: AccessibilitySocketTransport

    /// Opens it for a hardware UDID. `dump` is `remotectl dumpstate`, which
    /// contacts no device and gives the identifier `remoted` knows it by.
    init(device: String, dump: () throws -> Data = StaleDeviceConnection.liveDump) throws {
        guard let state = try? dump(), let identifier = StaleDeviceConnection.remoteIdentifier(in: state, device: device) else {
            throw CommandFailure(.deviceNotReady, "The Mac's remoted has no connected CoreDevice connection for the device; no accessibility connection was opened.", inputSent: .none)
        }
        var descriptor: Int32 = -1
        var handle: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 1024)
        guard ADCOpenAccessibilityShim(identifier, &descriptor, &handle, &error, error.count) == 0, let handle, descriptor >= 0 else {
            throw CommandFailure(.deviceNotReady, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        owner = handle
        do { transport = try AccessibilitySocketTransport(taking: descriptor) } catch {
            ADCReleaseAccessibilityShim(handle)
            throw error
        }
    }

    /// Closes the stream, then the service connection behind it.
    func close() {
        transport.close()
        if let owner { ADCReleaseAccessibilityShim(owner) }
        owner = nil
    }

    deinit { close() }
}
