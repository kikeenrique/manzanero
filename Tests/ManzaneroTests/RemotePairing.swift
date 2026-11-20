import CryptoKit
import Foundation
import Testing
@testable import Manzanero

/// The pairing's encodings and its conversation, against a device written
/// here from the same description: no device is contacted.
struct RemotePairingTests {
    @Test func tlvSplitsLongValuesAndJoinsThemBack() throws {
        let long = (0..<600).map { UInt8($0 % 251) }
        let encoded = PairingTLV.encode([.init(.state, [3]), .init(.publicKey, long), .init(.proof, [9, 9])])
        // 600 bytes go as 255 + 255 + 90, each with its two-byte header.
        #expect(encoded.count == 3 + 600 + 6 + 4 && encoded[3] == 0x03 && encoded[4] == 255)
        let decoded = try #require(PairingTLV.decode(encoded))
        #expect(decoded == [.init(.state, [3]), .init(.publicKey, long), .init(.proof, [9, 9])])
        #expect(PairingTLV.value(.proof, in: decoded) == [9, 9] && PairingTLV.value(.salt, in: decoded) == nil)
        // A length that runs past the end is refused, not read short.
        #expect(PairingTLV.decode([0x06, 0x05, 0x01]) == nil)
        // Two short items of one kind stay two.
        #expect(PairingTLV.decode([0x03, 1, 7, 0x03, 1, 8])?.count == 2)
    }

    @Test func opackWritesADictionaryOfStringsAndData() {
        let encoded = PairingOPACK.encode([("name", .string("manzanero")), ("mac", .data([1, 2, 3]))])
        #expect(encoded == [0xE2, 0x44] + Array("name".utf8) + [0x49] + Array("manzanero".utf8) + [0x43] + Array("mac".utf8) + [0x73, 1, 2, 3])
        // A string longer than 32 bytes carries its length in a byte of its own.
        let long = String(repeating: "a", count: 40)
        #expect(Array(PairingOPACK.encode([("k", .string(long))]).dropFirst(3).prefix(2)) == [0x61, 40])
    }

    @Test func framesCarryOneJSONMessage() throws {
        let frame = try PairingFrame.encode(PairingFrame.envelope(plain: ["a": 1], sequence: 7))
        #expect(Array(frame.prefix(9)) == Array("RPPairing".utf8) && Int(frame[9]) << 8 | Int(frame[10]) == frame.count - 11)
        var rest = frame[...]
        let message = try PairingFrame.decode { count in defer { rest = rest.dropFirst(count) }; return Array(rest.prefix(count)) }
        #expect(message["sequenceNumber"] as? Int == 7 && message["originatedBy"] as? String == "host")
        #expect(throws: CommandFailure.self) { try PairingFrame.decode { Array(repeating: 0, count: $0) } }
    }

    @Test func anIdentityIsStoredForItsOwnerOnly() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/pairing-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var identity = PairingIdentity.generate()
        identity.peerIdentifier = "peer"
        let udid = "00008110-000A11112222801E"
        #expect(PairingIdentity.load(udid: udid, directory: directory) == nil)
        try identity.save(udid: udid, directory: directory)
        #expect(PairingIdentity.load(udid: udid, directory: directory) == identity)
        let attributes = try FileManager.default.attributesOfItem(atPath: PairingIdentity.file(udid: udid, directory: directory).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Nothing but the identifier's own characters reaches the file name.
        #expect(PairingIdentity.file(udid: "../x/y", directory: directory).lastPathComponent == "xy.json")
    }

    /// The device's side of the handshake, pair-verify and the listener
    /// request, answering from a queue of frames as the client writes.
    private final class Device: PairingStream {
        let signing = Curve25519.Signing.PrivateKey()
        let identifier = "DEVICE-IDENTIFIER"
        /// The host identities the device knows: identifier to public key.
        var hosts: [String: Data] = [:]
        var listenerPort = 61234
        private var inbox: [UInt8] = [], outbox: [UInt8] = []
        private var shared: [UInt8] = [], devicePublic: [UInt8] = [], hostPublic: [UInt8] = []
        private(set) var listenerKey: Data?

        func send(_ bytes: [UInt8]) throws {
            inbox += bytes
            var rest = inbox[...]
            let message = try PairingFrame.decode { count in defer { rest = rest.dropFirst(count) }; return Array(rest.prefix(count)) }
            inbox = Array(rest)
            try answer(message)
        }

        func read(_ count: Int) throws -> [UInt8] {
            guard outbox.count >= count else { throw CommandFailure(.transportFailed, "The test device has nothing to say.", inputSent: .none) }
            defer { outbox.removeFirst(count) }
            return Array(outbox.prefix(count))
        }

        private func reply(plain value: [String: Any]) throws {
            outbox += try PairingFrame.encode(["message": ["plain": ["_0": value]], "originatedBy": "device", "sequenceNumber": 0])
        }

        private func reply(items: [PairingTLV.Item]) throws {
            try reply(plain: ["event": ["_0": ["pairingData": ["_0": ["data": Data(PairingTLV.encode(items)).base64EncodedString()]]]]])
        }

        private func key(_ salt: String?, _ info: String) -> SymmetricKey {
            let input = SymmetricKey(data: shared)
            if let salt { return HKDF<SHA512>.deriveKey(inputKeyMaterial: input, salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32) }
            return HKDF<SHA512>.deriveKey(inputKeyMaterial: input, info: Data(info.utf8), outputByteCount: 32)
        }

        private func answer(_ message: [String: Any]) throws {
            let body = message["message"] as? [String: Any]
            if let sealed = (body?["streamEncrypted"] as? [String: Any])?["_0"] as? String, let data = Data(base64Encoded: sealed) {
                let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
                let request = try ChaChaPoly.open(.init(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16)), using: key(nil, "ClientEncrypt-main"))
                let listener = (((try JSONSerialization.jsonObject(with: request) as? [String: Any])?["request"] as? [String: Any])?["_0"] as? [String: Any])?["createListener"] as? [String: Any]
                listenerKey = (listener?["key"] as? String).flatMap { Data(base64Encoded: $0) }
                let response = try JSONSerialization.data(withJSONObject: ["response": ["_1": ["createListener": ["port": listenerPort]]]])
                let box = try ChaChaPoly.seal(response, using: key(nil, "ServerEncrypt-main"), nonce: nonce)
                outbox += try PairingFrame.encode(["message": ["streamEncrypted": ["_0": (box.ciphertext + box.tag).base64EncodedString()]], "originatedBy": "device", "sequenceNumber": 1])
                return
            }
            let plain = (body?["plain"] as? [String: Any])?["_0"] as? [String: Any] ?? [:]
            if (plain["request"] as? [String: Any]) != nil { return try reply(plain: ["response": ["_1": ["handshake": ["_0": [String: Any]()]]]]) }
            let event = (plain["event"] as? [String: Any])?["_0"] as? [String: Any] ?? [:]
            guard let text = ((event["pairingData"] as? [String: Any])?["_0"] as? [String: Any])?["data"] as? String,
                  let items = Data(base64Encoded: text).flatMap({ PairingTLV.decode(Array($0)) }) else { return }
            if PairingTLV.value(.state, in: items) == [1], let host = PairingTLV.value(.publicKey, in: items) {
                let secret = Curve25519.KeyAgreement.PrivateKey()
                hostPublic = host
                devicePublic = Array(secret.publicKey.rawRepresentation)
                shared = try secret.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: Data(host))).withUnsafeBytes { Array($0) }
                let signature = try signing.signature(for: Data(devicePublic + Array(identifier.utf8) + hostPublic))
                let proof = PairingTLV.encode([.init(.identifier, Array(identifier.utf8)), .init(.signature, Array(signature))])
                let box = try ChaChaPoly.seal(Data(proof), using: key("Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info"),
                                              nonce: .init(data: Data([0, 0, 0, 0] + Array("PV-Msg02".utf8))))
                return try reply(items: [.init(.state, [2]), .init(.publicKey, devicePublic), .init(.encryptedData, Array(box.ciphertext + box.tag))])
            }
            if PairingTLV.value(.state, in: items) == [3], let sealed = PairingTLV.value(.encryptedData, in: items) {
                let opened = try ChaChaPoly.open(.init(nonce: .init(data: Data([0, 0, 0, 0] + Array("PV-Msg03".utf8))), ciphertext: Data(sealed.dropLast(16)), tag: Data(sealed.suffix(16))),
                                                 using: key("Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info"))
                let proof = PairingTLV.decode(Array(opened)) ?? []
                let host = String(decoding: PairingTLV.value(.identifier, in: proof) ?? [], as: UTF8.self)
                let signed = hostPublic + Array(host.utf8) + devicePublic
                let known = hosts[host].flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }?
                    .isValidSignature(Data(PairingTLV.value(.signature, in: proof) ?? []), for: Data(signed)) ?? false
                return try reply(items: known ? [.init(.state, [4])] : [.init(.state, [4]), .init(.error, [2])])
            }
        }
    }

    @Test func aKnownIdentityVerifiesAndGetsAListener() throws {
        let device = Device()
        var identity = PairingIdentity.generate()
        device.hosts[identity.identifier] = try identity.signingKey.publicKey.rawRepresentation
        identity.peerPublicKey = device.signing.publicKey.rawRepresentation
        let client = RemotePairingClient(stream: device)
        try client.handshake()
        #expect(try client.verify(identity))
        #expect(client.peerSignatureValid == true && client.sessionKey.count == 32)
        #expect(try client.createListener() == 61234)
        // The listener is keyed by the session's key, the tunnel's PSK.
        #expect(device.listenerKey == Data(client.sessionKey))
    }

    @Test func anUnknownIdentityIsRefusedAndAnImpostorIsNoticed() throws {
        let stranger = RemotePairingClient(stream: Device())
        try stranger.handshake()
        #expect(try !stranger.verify(.generate()))
        #expect(stranger.sessionKey.isEmpty)
        #expect(throws: CommandFailure.self) { try stranger.createListener() }
        // A device that knows the host but signs with another key than the
        // one kept at pairing.
        let device = Device()
        var identity = PairingIdentity.generate()
        device.hosts[identity.identifier] = try identity.signingKey.publicKey.rawRepresentation
        identity.peerPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let client = RemotePairingClient(stream: device)
        try client.handshake()
        #expect(try client.verify(identity))
        #expect(client.peerSignatureValid == false)
    }

    private static func details() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"],
                                                    "result": ["identifier": "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F", "properties": [
            "hardware": ["udid": "00008110-000A11112222801E", "reality": "physical"], "state": ["name": "Living Room"],
            "connection": ["state": "connected", "pairingState": "paired", "tunnelIPAddressString": "fd00::1"]]]])
    }

    @Test func pairLeavesAPairedDeviceAloneAndSaysWhenThePairingScreenIsClosed() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/pairing-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let udid = "00008110-000A11112222801E"
        let command = PairCommand(device: udid)
        #expect(try PairCommand.subject(details: Self.details(), requested: udid) == .init(udid: udid, name: "Living Room", address: "fd00::1"))

        // No identity and no manual-pairing service: nothing is changed.
        var environment = PairCommand.Environment(identities: directory)
        environment.connect = { _, _ in Issue.record("pair connected without a service to pair at"); throw CancellationError() }
        environment.manualPairingPort = { name in #expect(name == "Living Room"); return nil }
        let closed = #expect(throws: CommandFailure.self) { try command.execute(details: Self.details(), environment: environment) }
        #expect(closed?.code == .deviceNotReady && closed?.description.contains("Remote App and Devices") == true)

        // A stored identity the device knows: already paired, at the main service.
        let device = Device()
        var identity = PairingIdentity.generate()
        device.hosts[identity.identifier] = try identity.signingKey.publicKey.rawRepresentation
        identity.peerPublicKey = device.signing.publicKey.rawRepresentation
        try identity.save(udid: udid, directory: directory)
        environment.connect = { host, port in #expect(host == "fd00::1" && port == DeviceTunnel.pairingPort); return device }
        environment.manualPairingPort = { _ in Issue.record("pair looked for a pairing screen for a paired device"); return nil }
        let paired = try #require(JSONSerialization.jsonObject(with: command.execute(details: Self.details(), environment: environment)) as? [String: Any])
        #expect(paired["status"] as? String == "already-paired")

        // --forget deletes the identity and contacts nothing.
        environment.connect = { _, _ in Issue.record("forget connected to the device"); throw CancellationError() }
        var forget = command
        forget.forget = true
        let forgotten = try #require(JSONSerialization.jsonObject(with: forget.execute(details: Self.details(), environment: environment)) as? [String: Any])
        #expect(forgotten["status"] as? String == "forgotten" && PairingIdentity.load(udid: udid, directory: directory) == nil)
        let again = try #require(JSONSerialization.jsonObject(with: forget.execute(details: Self.details(), environment: environment)) as? [String: Any])
        #expect(again["status"] as? String == "not-paired")
    }

    @Test func pairIsACommandWithAPlanAndStaysOutOfABatch() async throws {
        let udid = "00008110-000A11112222801E"
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        let output = try await service.run(["pair", "--device", udid, "--pin-file", "pin.txt"], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["operation"] as? String == "pair" && (plan["pinSource"] as? String)?.contains("pin.txt") == true)
        await #expect(throws: CommandFailure.self) { try await service.run(["pair", "--simulator", UUID().uuidString], dryRun: true) }
        await #expect(throws: CommandFailure.self) { try await service.run(["batch", "--device", udid, #"[["pair"]]"#], dryRun: true) }
        #expect(PairingDiscovery.name(txt: [4] + Array("a=b1".utf8) + [16] + Array("name=Living Room".utf8)) == "Living Room")
        #expect(PairingDiscovery.name(txt: [9, 1]) == nil)
    }
}
