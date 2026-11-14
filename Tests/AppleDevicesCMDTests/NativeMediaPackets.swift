import AppleDeviceBridge
import Foundation
import ImageIO
import Testing
import XPC
@testable import AppleDevicesCMD

struct NativeMediaPacketsTests {
    @Test(arguments: ["valid", "error", "missing", "transport", "cipher", "rtcpCipher", "boolean", "zero", "axis", "pixels", "rate", "payload"])
    func packetProfileRequiresBoundedPlainRTP(mutation: String) {
        let root = xpc_dictionary_create(nil, nil, 0), output = xpc_dictionary_create(nil, nil, 0)
        let connection = xpc_dictionary_create(nil, nil, 0), config = xpc_dictionary_create(nil, nil, 0)
        for (key, value): (String, UInt64) in ["TransportProtocolType": 2, "SRTPCipherSuite": 0, "SRTCPCipherSuite": 0,
            "CustomWidth": 1136, "CustomHeight": 2448, "Framerate": 60, "TxPayloadType": 100] {
            xpc_dictionary_set_uint64(config, key, value)
        }
        xpc_dictionary_set_value(connection, "streamConfig", config)
        xpc_dictionary_set_value(output, "connection", connection)
        xpc_dictionary_set_value(root, "CoreDevice.output", output)
        switch mutation {
        case "error": xpc_dictionary_set_value(root, "CoreDevice.error", xpc_dictionary_create(nil, nil, 0))
        case "missing": xpc_dictionary_set_value(config, "TransportProtocolType", nil)
        case "transport": xpc_dictionary_set_uint64(config, "TransportProtocolType", 1)
        case "cipher": xpc_dictionary_set_uint64(config, "SRTPCipherSuite", 1)
        case "rtcpCipher": xpc_dictionary_set_uint64(config, "SRTCPCipherSuite", 1)
        case "boolean": xpc_dictionary_set_bool(config, "Framerate", true)
        case "zero": xpc_dictionary_set_uint64(config, "CustomWidth", 0)
        case "axis": xpc_dictionary_set_uint64(config, "CustomWidth", 8193)
        case "pixels":
            xpc_dictionary_set_uint64(config, "CustomWidth", 5000)
            xpc_dictionary_set_uint64(config, "CustomHeight", 5000)
        case "rate": xpc_dictionary_set_uint64(config, "Framerate", 241)
        case "payload": xpc_dictionary_set_uint64(config, "TxPayloadType", 128)
        default: break
        }
        var profile = ADCVideoPacketProfile(), error = [CChar](repeating: 0, count: 512)
        profile.width = 99
        let status = ADCValidateVideoPacketProfile(Unmanaged.passUnretained(root).toOpaque(), &profile, &error, error.count)
        #expect((status == 0) == (mutation == "valid"))
        #expect(profile.width == (mutation == "valid" ? 1136 : 0))
    }

    @Test func invalidPacketOwnerNeverDeliversData() {
        var deliveries = 0, error = [CChar](repeating: 0, count: 512)
        #expect(ADCCopyNextVideoPacket(nil, { 0 }, { _, _ in deliveries += 1 }, &error, error.count) == -1)
        #expect(deliveries == 0)
        var owner: UnsafeMutableRawPointer?
        #expect(ADCCreateVideoPacketSession("invalid", "651.32", "utun0", "fd00::1", "fd00::2", { 0 }, &owner, &error, error.count) != 0)
        #expect(owner == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_PACKETS_DEVICE"] != nil))
    @MainActor func explicitLiveStandardRTPPacketDeliveryAndOwnedStop() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_PACKETS_DEVICE"])
        let input = CoreDeviceInput(device: device, operation: "media-status", operands: [])
        let details = try ToolRunner().run(input.identityPlan().arguments, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        let assertion = try NativeTunnelAssertion(device: device, details: details)
        defer { assertion.close() }
        let inventory = try ToolRunner().run(["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"])
        let endpoint = try NativeMediaEndpoint.resolve(details: details, inventory: inventory, requested: device)
        let display = try DirectTouchDisplay(ToolRunner().run(AccessibilityDisplay.plan(device: identity.uuid).arguments, timeout: 15))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/media-packets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = ["stage": "local-prepare", "datagrams": 0]
        var frames: NativeMediaFrames?
        var decoder: NativeHEVCDecoder?
        defer { decoder?.close() }
        let decode = ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_PACKETS_DECODE"] == "1"
        func record() throws {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        }
        do {
            frames = try NativeMediaFrames(endpoint: endpoint, version: identity.version, packets: true)
            metadata["stage"] = "start"
            try frames?.start(displayID: Int64(display.id))
            metadata["negotiated"] = frames?.packetProfile()
            if decode {
                let profile = try #require(frames?.packetProfile())
                decoder = try NativeHEVCDecoder(width: Int(try #require(profile["width"])), height: Int(try #require(profile["height"])))
            }
            if ProcessInfo.processInfo.environment["APPLEDEVICES_MEDIA_PACKETS_HOME"] == "1" {
                _ = try DirectPhysicalInput.execute(CoreDeviceInput(device: device, operation: "button", operands: ["home"]),
                    query: { try ToolRunner().run($0.arguments, timeout: 20) })
                metadata["homeDispatched"] = true
            }
            metadata["stage"] = "packets"
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            var end: ContinuousClock.Instant?
            var count = 0, bytes = 0, rtp = 0, rtcp = 0
            var payloadTypes = Set<UInt8>()
            var payloadOctets: [String: Int] = [:]
            var configurationTags: [String: Int] = [:]
            var assembler = MediaHEVCAssembler()
            var units = 0, decoded = 0
            while true {
                try Task.checkCancellation()
                if let end, ContinuousClock.now >= end { break }
                guard end != nil || ContinuousClock.now < deadline else { throw CommandFailure(description: "Native RTP probe exceeded its six-second first-packet budget.") }
                if let packet = try frames?.nextPacket() {
                    if end == nil { end = ContinuousClock.now.advanced(by: .seconds(2)) }
                    count += 1; bytes += packet.count
                    guard count <= 10_000, bytes <= 32 * 1024 * 1024 else { throw CommandFailure(description: "Native packet probe exceeded its collection bounds.") }
                    if packet.count >= 2, packet[0] >> 6 == 2 {
                        if (192...223).contains(packet[1]) { rtcp += 1 }
                        else if packet.count >= 12 { rtp += 1; payloadTypes.insert(packet[1] & 0x7f) }
                    }
                    metadata["datagrams"] = count; metadata["bytes"] = bytes
                    metadata["rtpHeaderCount"] = rtp; metadata["rtcpHeaderCount"] = rtcp
                    metadata["payloadTypes"] = payloadTypes.sorted()
                    if let type = frames?.packetProfile()?["payloadType"], let type = UInt8(exactly: type),
                       let parsed = MediaRTPPacket(packet, payloadType: type), let octet = parsed.payload.first {
                        payloadOctets[String(octet), default: 0] += 1
                        for tag in ["avcC", "hvcC"] where parsed.payload.range(of: Data(tag.utf8)) != nil {
                            configurationTags[tag, default: 0] += 1
                        }
                        metadata["payloadFirstOctets"] = payloadOctets
                        metadata["configurationTagOccurrences"] = configurationTags
                        if decode, let unit = try assembler.accept(parsed) {
                            units += 1; metadata["accessUnits"] = units
                            if let jpeg = try decoder?.decode(unit) {
                                let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
                                #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
                                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                                    metadata["decodedWidth"] = properties[kCGImagePropertyPixelWidth]
                                    metadata["decodedHeight"] = properties[kCGImagePropertyPixelHeight]
                                }
                                if decoded == 0 {
                                    #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent("first.jpg").path,
                                        contents: jpeg, attributes: [.posixPermissions: 0o600]))
                                }
                                decoded += 1; metadata["decodedFrames"] = decoded
                            }
                        }
                    }
                } else { try await Task.sleep(for: .milliseconds(2)) }
            }
            if let decoder { decoder.close(); metadata["videoToolboxInvalidationReturned"] = true }
            let cleanup = try #require(frames?.close())
            metadata["cleanup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup))
            metadata["assertionRelease"] = assertion.close().status
            metadata["outcome"] = "received-packets"
            try record()
            #expect(rtp > 0 && cleanup.stopAcknowledged && cleanup.ownedStreamAbsent)
            if decode { #expect(decoded > 0) }
        } catch {
            if let decoder { decoder.close(); metadata["videoToolboxInvalidationReturned"] = true }
            metadata["negotiated"] = frames?.packetProfile()
            if let cleanup = frames?.close() { metadata["cleanup"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup)) }
            metadata["outcome"] = "failed"; metadata["error"] = String(describing: error)
            metadata["assertionRelease"] = assertion.close().status
            try? record()
            throw error
        }
    }
}
