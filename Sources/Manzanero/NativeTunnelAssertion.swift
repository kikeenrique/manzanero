import AppleDeviceBridge
import Foundation

/// Single-task owner of an existing paired device's Apple tunnel assertion.
/// It never initiates pairing or exposes the opaque assertion identifier.
final class NativeTunnelAssertion {
    struct Release: Encodable {
        let confirmed: Bool
        let status: String
        let diagnostic: String?
    }

    /// Browses at most this many times when the browse connection is interrupted.
    static let browseAttempts = 5

    let address: String
    private var owner: UnsafeMutableRawPointer?
    private var released: Release?

    init(device: String, details: Data) throws {
        try Task.checkCancellation()
        let expected = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: device)
        var address = [CChar](repeating: 0, count: 128)
        var error = [CChar](repeating: 0, count: 1024)
        var owner: UnsafeMutableRawPointer?
        var status = ADCOpenNativeTunnelAssertion(device, { Task.isCancelled ? 1 : 0 }, &address, address.count, &owner, &error, error.count)
        // The pairing daemon's browse connection occasionally reports an error
        // before it announces the device. Nothing has been requested at that
        // point, so browse again, a bounded number of times.
        var attempts = 1
        while status == ADCTunnelBrowseInterrupted, owner == nil, attempts < Self.browseAttempts, !Task.isCancelled {
            // 0.25, 0.5, 1 and 2 seconds: three quick attempts were once not enough.
            Thread.sleep(forTimeInterval: 0.25 * Double(1 << (attempts - 1)))
            attempts += 1
            status = ADCOpenNativeTunnelAssertion(device, { Task.isCancelled ? 1 : 0 }, &address, address.count, &owner, &error, error.count)
        }
        if Task.isCancelled {
            let release = Self.release(owner)
            if status != 0 {
                let diagnostic = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !diagnostic.isEmpty { FileHandle.standardError.write(Data("\(diagnostic)\n".utf8)) }
            }
            if !release.confirmed { FileHandle.standardError.write(Data("\(release.diagnostic ?? "Tunnel cleanup unconfirmed")\n".utf8)) }
            throw CancellationError()
        }
        guard status == 0, let owner else {
            _ = Self.release(owner)
            // The assertion only opens a tunnel; it never sends device input.
            throw CommandFailure(.transportFailed, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        let value = String(decoding: address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        do {
            _ = try RSDPortDiscovery.socketAddress(value, port: 1)
            guard value == expected else { throw CommandFailure(.preconditionChanged, "Apple assertion address differs from fresh selected-device details; discard it and refresh discovery.", inputSent: .none) }
        } catch {
            let release = Self.release(owner)
            throw CommandFailure("\(error) Assertion release confirmed=\(release.confirmed); \(release.diagnostic ?? release.status)", wrapping: error).noInputSent()
        }
        self.owner = owner
        self.address = value
    }

    deinit { _ = close() }
    @discardableResult func close() -> Release {
        if let released { return released }
        let saved = owner
        owner = nil
        let outcome = Self.release(saved)
        released = outcome
        return outcome
    }

    private static func release(_ owner: UnsafeMutableRawPointer?) -> Release {
        guard let owner else { return Release(confirmed: true, status: "not-held", diagnostic: nil) }
        var error = [CChar](repeating: 0, count: 512)
        let status = ADCCloseNativeTunnelAssertion(owner, &error, error.count)
        return Release(confirmed: status == 0, status: status == 0 ? "acknowledged" : "unconfirmed",
            diagnostic: status == 0 ? nil : String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}
