import AppleDeviceBridge
import Darwin
import Foundation
import Testing
@testable import AppleDevicesCMD

struct NativeRemoteXPCWireTests {
    private struct Outcome: Sendable {
        let status: Int32
        let diagnostic: String
    }

    private func localListener() throws -> (Int32, sockaddr_in6) {
        let listener = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var transferred = false
        defer { if !transferred { Darwin.close(listener) } }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        try #require(named == 0)
        transferred = true
        return (listener, address)
    }

    private func localPair() throws -> (Int32, Int32) {
        let (listener, selected) = try localListener()
        defer { Darwin.close(listener) }
        var address = selected
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let client = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(client >= 0)
        var transferred = false
        defer { if !transferred { Darwin.close(client) } }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait))) == 0)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, size) }
        }
        try #require(connected == 0)
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        try #require(poll(&pending, 1, 2000) > 0)
        let peer = accept(listener, nil, nil)
        try #require(peer >= 0)
        transferred = true
        return (client, peer)
    }

    private func capture(_ peer: Int32) throws -> Data {
        let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var bytes = Data()
        var settingsSent = false
        var lastByte = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var pending = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            let result = poll(&pending, 1, 10)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if result == 0 {
                if settingsSent && lastByte.duration(to: .now) > .milliseconds(300) { break }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(peer, &chunk, chunk.count, MSG_DONTWAIT)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count <= 65536 - bytes.count else { throw CommandFailure(description: "Local native RemoteXPC prefix exceeded 64 KiB.") }
            bytes.append(contentsOf: chunk.prefix(count))
            lastByte = .now
            if bytes.count >= preface.count && !settingsSent {
                guard bytes.starts(with: preface) else { break }
                // The owned peer sends only standard empty HTTP/2 SETTINGS.
                // No device traffic is intercepted, replayed or modified.
                let settings: [UInt8] = [0, 0, 0, 4, 0, 0, 0, 0, 0]
                try #require(send(peer, settings, settings.count, MSG_NOSIGNAL) == settings.count)
                settingsSent = true
            }
        }
        return bytes
    }

    private func frameMetadata(_ bytes: Data) -> [[String: Any]] {
        let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        guard bytes.starts(with: preface) else { return [] }
        var cursor = preface.count
        var frames: [[String: Any]] = []
        while bytes.count - cursor >= 9, frames.count < 64 {
            let length = Int(bytes[cursor]) << 16 | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            guard length <= bytes.count - cursor - 9 else { break }
            let stream = bytes[(cursor + 5)..<(cursor + 9)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fff_ffff
            frames.append(["type": bytes[cursor + 3], "flags": bytes[cursor + 4], "stream": stream, "length": length,
                "payloadPrefixHex": bytes[(cursor + 9)..<(cursor + 9 + min(length, 32))].map { String(format: "%02x", $0) }.joined()])
            cursor += 9 + length
        }
        return frames
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_NATIVE_RSD_WIRE"] == "1"))
    func observesAppleRemoteXPCPrefixOnlyOnOwnedLoopbackPeer() async throws {
        let mode = UInt64(ProcessInfo.processInfo.environment["APPLEDEVICES_NATIVE_RSD_WIRE_MODE"] ?? "0") ?? UInt64.max
        try #require(mode == 0 || mode == 4)
        let network = ProcessInfo.processInfo.environment["APPLEDEVICES_NATIVE_RSD_WIRE_NETWORK"] == "1"
        try #require(!network || mode == 0)
        let peer: Int32
        let call: Task<Outcome, Never>
        if network {
            let (listener, selected) = try localListener()
            let networkPort = selected.sin6_port
            call = Task { @concurrent in
                var target = sockaddr_in6()
                target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                target.sin6_family = sa_family_t(AF_INET6)
                target.sin6_addr = in6addr_loopback
                target.sin6_port = networkPort
                var port: UInt16 = 0
                var owner: UnsafeMutableRawPointer?
                var error = [CChar](repeating: 0, count: 1024)
                let status = withUnsafePointer(to: &target) {
                    ADCOpenRSDDirectoryNetwork($0, MemoryLayout<sockaddr_in6>.size, "00000000-0000000000000001", "11111111-1111-1111-1111-111111111111",
                        0x0100000000000006, { Task.isCancelled ? 1 : 0 }, &port, &owner, &error, error.count)
                }
                ADCCloseRSDDirectory(owner)
                return Outcome(status: status, diagnostic: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, 2000)
            peer = ready > 0 ? accept(listener, nil, nil) : -1
            Darwin.close(listener)
            if peer < 0 {
                call.cancel()
                let result = await call.value
                throw CommandFailure(description: "Native Network loopback peer did not connect: \(result.diagnostic)")
            }
        } else {
            let pair = try localPair()
            peer = pair.1
            let client = pair.0
            call = Task { @concurrent in
                var port: UInt16 = 0
                var owner: UnsafeMutableRawPointer?
                var error = [CChar](repeating: 0, count: 1024)
                let status = ADCOpenRSDDirectory(client, "00000000-0000000000000001", "11111111-1111-1111-1111-111111111111",
                    0x0100000000000006, mode, { Task.isCancelled ? 1 : 0 }, &port, &owner, &error, error.count)
                ADCCloseRSDDirectory(owner)
                return Outcome(status: status, diagnostic: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        defer { Darwin.close(peer) }
        let bytes: Data
        do { bytes = try capture(peer) }
        catch {
            call.cancel()
            shutdown(peer, SHUT_RDWR)
            _ = await call.value
            throw error
        }
        shutdown(peer, SHUT_RDWR)
        let result = await call.value
        let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/native-rsd-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: directory.appendingPathComponent("client-prefix.bin"))
        let frames = frameMetadata(bytes)
        let metadata: [String: Any] = ["source": "native Apple RemoteXPC to owned IPv6 loopback peer", "physicalDeviceQueried": false,
            "byteCount": bytes.count, "transport": network ? "network" : "connected-fd", "modeFlags": network ? 2 : mode, "startsWithHTTP2Preface": bytes.starts(with: preface), "frames": frames,
            "bridgeStatus": result.status, "bridgeDiagnostic": result.diagnostic, "directoryHandshakeCompleted": false,
            "bootstrapVersionFlagsSource": "Apple xpc_remote_connection_get_failsafe_version_flags", "advertisedVersionFlagsHex": "100000000000006"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        #expect(bytes.starts(with: preface))
        #expect(frames.isEmpty == false)
        // This peer intentionally returns no directory metadata. A failed native
        // directory result is expected and is not a device connectivity result.
        #expect(result.status != 0)
    }
}
