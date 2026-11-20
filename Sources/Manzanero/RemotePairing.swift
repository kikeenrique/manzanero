import CryptoKit
import Foundation

/// The identity this tool pairs with one device under, and what the device
/// said of itself when it was paired. It holds a private key: the file is
/// written for its owner only, under Application Support, and never in a
/// repository.
struct PairingIdentity: Codable, Equatable {
    var identifier: String
    var privateKey: Data
    var peerIdentifier: String?
    var peerPublicKey: Data?

    static func generate() -> PairingIdentity {
        PairingIdentity(identifier: UUID().uuidString, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) }
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/manzanero/pairings")
    }

    static func file(udid: String, directory: URL = PairingIdentity.directory) -> URL {
        directory.appendingPathComponent(udid.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }

    static func load(udid: String, directory: URL = PairingIdentity.directory) -> PairingIdentity? {
        (try? Data(contentsOf: file(udid: udid, directory: directory))).flatMap { try? JSONDecoder().decode(PairingIdentity.self, from: $0) }
    }

    func save(udid: String, directory: URL = PairingIdentity.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = Self.file(udid: udid, directory: directory)
        try JSONEncoder().encode(self).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// What the pairing conversation runs over: a connection that sends bytes
/// and returns exactly as many as are asked for.
protocol PairingStream {
    func send(_ bytes: [UInt8]) throws
    func read(_ count: Int) throws -> [UInt8]
}

/// The host's side of Apple's remote pairing, as far as this tool needs it:
/// the handshake, pair-verify with a stored identity, pair-setup with the
/// PIN a device shows, and the request for a tunnel listener
/// (docs/transport.md#a-pairing-of-the-tools-own). The messages are the ones
/// the reference project sends (github.com/jkcoxson/idevice, MIT; nothing
/// copied). It contacts only the pairing service; it opens no tunnel itself.
final class RemotePairingClient {
    static let wireProtocolVersion = 19
    /// The name the device lists this host under.
    static let hostName = "manzanero"

    private let stream: any PairingStream
    private var sequence = 0
    private var encryptedSequence: UInt64 = 0
    /// The key of the session: X25519's shared secret after pair-verify.
    /// It is also the pre-shared key of the tunnel's TLS.
    private(set) var sessionKey: [UInt8] = []
    /// Whether the device's signature was checked against the key it gave
    /// at pairing; nil when there was nothing to check it with.
    private(set) var peerSignatureValid: Bool?

    init(stream: any PairingStream) { self.stream = stream }

    // MARK: Messages

    private func send(plain value: [String: Any]) throws {
        try stream.send(PairingFrame.encode(PairingFrame.envelope(plain: value, sequence: sequence)))
        sequence += 1
    }

    /// The next message: what is inside `message.plain._0`, or the whole
    /// message when it is not a plain one.
    private func receive() throws -> [String: Any] {
        let message = try PairingFrame.decode(read: stream.read)
        let plain = ((message["message"] as? [String: Any])?["plain"] as? [String: Any])?["_0"] as? [String: Any]
        return plain ?? message
    }

    private static func failure(_ text: String) -> CommandFailure {
        CommandFailure(.transportFailed, "Remote pairing: \(text)", inputSent: .none)
    }

    private func sendPairingData(_ items: [PairingTLV.Item], kind: String, newSession: Bool, withHost: Bool) throws {
        var data: [String: Any] = ["data": Data(PairingTLV.encode(items)).base64EncodedString(), "kind": kind, "startNewSession": newSession]
        if withHost { data["sendingHost"] = Self.hostName }
        try send(plain: ["event": ["_0": ["pairingData": ["_0": data]]]])
    }

    /// The reason a device gives when it rejects a pairing.
    private static func rejection(_ event: [String: Any]) -> String? {
        guard let rejected = event["pairingRejectedWithError"] as? [String: Any] else { return nil }
        let info = (rejected["wrappedError"] as? [String: Any])?["userInfo"] as? [String: Any]
        return info?["NSLocalizedDescription"] as? String ?? "no reason given"
    }

    private static func pairingItems(_ message: [String: Any]) throws -> [PairingTLV.Item] {
        guard let event = (message["event"] as? [String: Any])?["_0"] as? [String: Any] else {
            throw failure("a message without an event where pairing data was expected")
        }
        if let reason = rejection(event) { throw failure("the device rejected the pairing: \(reason)") }
        guard let text = ((event["pairingData"] as? [String: Any])?["_0"] as? [String: Any])?["data"] as? String,
              let data = Data(base64Encoded: text), let items = PairingTLV.decode(Array(data)) else {
            throw failure("pairing data that could not be read")
        }
        return items
    }

    private static func key(_ material: [UInt8], salt: String?, info: String) -> SymmetricKey {
        let input = SymmetricKey(data: material)
        if let salt {
            return HKDF<SHA512>.deriveKey(inputKeyMaterial: input, salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        return HKDF<SHA512>.deriveKey(inputKeyMaterial: input, info: Data(info.utf8), outputByteCount: 32)
    }

    private static func nonce(_ label: String) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0] + Array(label.utf8)))
    }

    private static func seal(_ plaintext: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce) throws -> [UInt8] {
        let box = try ChaChaPoly.seal(Data(plaintext), using: key, nonce: nonce)
        return Array(box.ciphertext + box.tag)
    }

    private static func open(_ sealed: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce) throws -> [UInt8] {
        guard sealed.count >= 16 else { throw failure("an encrypted item shorter than its tag") }
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: Data(sealed.dropLast(16)), tag: Data(sealed.suffix(16)))
        return Array(try ChaChaPoly.open(box, using: key))
    }

    // MARK: Handshake and pair-verify

    func handshake() throws {
        try send(plain: ["request": ["_0": ["handshake": ["_0": [
            "hostOptions": ["attemptPairVerify": true], "wireProtocolVersion": Self.wireProtocolVersion]]]]])
        let response = try receive()
        guard ((response["response"] as? [String: Any])?["_1"] as? [String: Any])?["handshake"] != nil else {
            throw Self.failure("no handshake in the device's first answer")
        }
    }

    private func sendVerifyFailed() throws {
        try send(plain: ["event": ["_0": ["pairVerifyFailed": [String: Any]()]]])
    }

    /// Pair-verify. True when the device knows this identity, and the
    /// session key is then set; false when it does not, with the connection
    /// left ready for `setup`.
    func verify(_ identity: PairingIdentity) throws -> Bool {
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = Array(secret.publicKey.rawRepresentation)
        try sendPairingData([.init(.state, [1]), .init(.publicKey, publicKey)], kind: "verifyManualPairing", newSession: true, withHost: false)
        let first = try Self.pairingItems(receive())
        if PairingTLV.value(.error, in: first) != nil {
            try sendVerifyFailed()
            return false
        }
        guard let devicePublic = PairingTLV.value(.publicKey, in: first), devicePublic.count == 32 else {
            throw Self.failure("no public key in the device's answer to pair-verify")
        }
        let shared = try secret.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: Data(devicePublic)))
        let sharedBytes = shared.withUnsafeBytes { Array($0) }
        let verifyKey = Self.key(sharedBytes, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")

        // The device's own proof: its identifier and a signature over both
        // public keys, checked when its key was kept at pairing.
        if let sealed = PairingTLV.value(.encryptedData, in: first), let peerKey = identity.peerPublicKey,
           let opened = try? Self.open(sealed, key: verifyKey, nonce: Self.nonce("PV-Msg02")),
           let items = PairingTLV.decode(opened), let peerIdentifier = PairingTLV.value(.identifier, in: items),
           let signature = PairingTLV.value(.signature, in: items) {
            let signed = devicePublic + peerIdentifier + publicKey
            peerSignatureValid = (try? Curve25519.Signing.PublicKey(rawRepresentation: peerKey))?.isValidSignature(Data(signature), for: Data(signed)) ?? false
        }

        let identifier = Array(identity.identifier.utf8)
        let signature = try identity.signingKey.signature(for: Data(publicKey + identifier + devicePublic))
        let proof = PairingTLV.encode([.init(.identifier, identifier), .init(.signature, Array(signature))])
        let sealed = try Self.seal(proof, key: verifyKey, nonce: Self.nonce("PV-Msg03"))
        try sendPairingData([.init(.state, [3]), .init(.encryptedData, sealed)], kind: "verifyManualPairing", newSession: false, withHost: false)
        let second = try Self.pairingItems(receive())
        if PairingTLV.value(.error, in: second) != nil {
            try sendVerifyFailed()
            return false
        }
        sessionKey = sharedBytes
        return true
    }

    // MARK: Pair-setup

    /// Pair-setup, for a device that does not know this identity. An Apple
    /// TV answers the first message with its salt and public value and
    /// shows a PIN, which `pin` returns; a phone asks its user to allow the
    /// host instead and then uses `000000`. The identity gets what the
    /// device says of itself. Verify again on a new connection afterwards.
    func setup(_ identity: inout PairingIdentity, pin: () throws -> String) throws {
        try sendPairingData([.init(.method, [0]), .init(.state, [1])], kind: "setupManualPairing", newSession: true, withHost: true)
        let answer = try receive()
        guard let event = (answer["event"] as? [String: Any])?["_0"] as? [String: Any] else {
            throw Self.failure("no event in the device's answer to pair-setup")
        }
        if let reason = Self.rejection(event) { throw Self.failure("the device rejected the pairing: \(reason)") }
        let consent = event["awaitingUserConsent"] != nil
        let start = consent ? try Self.pairingItems(receive()) : try Self.pairingItems(answer)
        if let code = PairingTLV.value(.error, in: start) { throw Self.failure("the device answered pair-setup with error \(code)") }
        guard let salt = PairingTLV.value(.salt, in: start), let serverPublic = PairingTLV.value(.publicKey, in: start) else {
            throw Self.failure("no salt or public key in the device's answer to pair-setup")
        }
        let code = consent ? "000000" : try pin()
        guard code.utf8.count >= 6 else { throw CommandFailure.usage("The pairing PIN has six digits.") }
        let secret = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        guard let session = PairingSRP.session(secret: secret, password: Array(code.utf8.prefix(6)), salt: salt, serverPublicKey: serverPublic) else {
            throw Self.failure("the device sent a public value no honest device sends")
        }
        try sendPairingData([.init(.state, [3]), .init(.publicKey, session.publicKey), .init(.proof, session.proof)],
                            kind: "setupManualPairing", newSession: false, withHost: true)
        let proof = try Self.pairingItems(receive())
        if let code = PairingTLV.value(.error, in: proof) {
            throw CommandFailure(.targetUnresolved, "Remote pairing: the device refused the PIN (error \(code)). Read it again from the screen and pair again.", inputSent: .none)
        }
        guard PairingTLV.value(.proof, in: proof) == session.serverProof else {
            throw Self.failure("the device's proof does not match: it does not know the PIN it showed")
        }

        // The host's long-term key, its identifier and a signature, sealed.
        let setupKey = Self.key(session.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let signing = try identity.signingKey
        let identifier = Array(identity.identifier.utf8), publicKey = Array(signing.publicKey.rawRepresentation)
        let signSalt = Self.key(session.key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let signed = signSalt.withUnsafeBytes { Array($0) } + identifier + publicKey
        let signature = try signing.signature(for: Data(signed))
        let address = (0..<6).map { _ in UInt8.random(in: .min ... .max) }
        let info = PairingOPACK.encode([
            ("altIRK", .data((0..<16).map { _ in UInt8.random(in: .min ... .max) })),
            ("btAddr", .string(address.map { String(format: "%02X", $0) }.joined(separator: ":"))),
            ("mac", .data(address)),
            ("remotepairing_serial_number", .string("AAAAAAAAAAAA")),
            ("accountID", .string(identity.identifier)),
            ("model", .string("computer-model")),
            ("name", .string(Self.hostName))])
        let record = PairingTLV.encode([.init(.identifier, identifier), .init(.publicKey, publicKey),
                                        .init(.signature, Array(signature)), .init(.info, info)])
        let sealed = try Self.seal(record, key: setupKey, nonce: Self.nonce("PS-Msg05"))
        try sendPairingData([.init(.encryptedData, sealed), .init(.state, [5])], kind: "setupManualPairing", newSession: false, withHost: true)
        let last = try Self.pairingItems(receive())
        if let code = PairingTLV.value(.error, in: last) { throw Self.failure("the device refused the host's record (error \(code))") }
        guard let sealedPeer = PairingTLV.value(.encryptedData, in: last),
              let peer = PairingTLV.decode(try Self.open(sealedPeer, key: setupKey, nonce: Self.nonce("PS-Msg06"))) else {
            throw Self.failure("no record of the device in its last pair-setup message")
        }
        identity.peerIdentifier = PairingTLV.value(.identifier, in: peer).map { String(decoding: $0, as: UTF8.self) }
        identity.peerPublicKey = PairingTLV.value(.publicKey, in: peer).map { Data($0) }
    }

    // MARK: After pair-verify

    /// Asks the device for a TCP listener for a tunnel, keyed by this
    /// session's key, and returns its port. Only after `verify` is true.
    func createListener() throws -> UInt16 {
        guard !sessionKey.isEmpty else { throw CommandFailure(.internal, "Remote pairing: a listener was asked for before pair-verify.", inputSent: .none) }
        let request: [String: Any] = ["request": ["_0": ["createListener": [
            "key": Data(sessionKey).base64EncodedString(), "transportProtocolType": "tcp"]]]]
        let plaintext = Array(try JSONSerialization.data(withJSONObject: request))
        var counter = encryptedSequence.littleEndian
        let nonce = try ChaChaPoly.Nonce(data: Data(bytes: &counter, count: 8) + Data([0, 0, 0, 0]))
        let sealed = try Self.seal(plaintext, key: Self.key(sessionKey, salt: nil, info: "ClientEncrypt-main"), nonce: nonce)
        try stream.send(PairingFrame.encode(PairingFrame.envelope(encrypted: sealed, sequence: sequence)))
        sequence += 1
        let answer = try receive()
        guard let text = ((answer["message"] as? [String: Any])?["streamEncrypted"] as? [String: Any])?["_0"] as? String,
              let data = Data(base64Encoded: text) else {
            throw Self.failure("no encrypted answer to the request for a listener")
        }
        let opened = try Self.open(Array(data), key: Self.key(sessionKey, salt: nil, info: "ServerEncrypt-main"), nonce: nonce)
        encryptedSequence += 1
        let response = (try JSONSerialization.jsonObject(with: Data(opened)) as? [String: Any])?["response"] as? [String: Any]
        guard let listener = (response?["_1"] as? [String: Any])?["createListener"] as? [String: Any],
              let port = (listener["port"] as? NSNumber)?.intValue, let exact = UInt16(exactly: port), exact > 0 else {
            throw Self.failure("the device gave no listener: \(String(decoding: opened.prefix(300), as: UTF8.self))")
        }
        return exact
    }
}

/// A TCP connection to a device's pairing service, blocking, with a deadline
/// on every read and write.
final class PairingSocket: PairingStream {
    private let descriptor: Int32

    init(host: String, port: UInt16, seconds: Int = 20) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw CommandFailure(.deviceNotReady, "Remote pairing: the address \(host) could not be resolved.", inputSent: .none)
        }
        defer { freeaddrinfo(list) }
        var connected: Int32 = -1
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = entry, connected < 0 {
            let socket = Darwin.socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            if socket >= 0 {
                var timeout = timeval(tv_sec: seconds, tv_usec: 0)
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                if connect(socket, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 { connected = socket } else { Darwin.close(socket) }
            }
            entry = candidate.pointee.ai_next
        }
        guard connected >= 0 else {
            throw CommandFailure(.deviceNotReady, "Remote pairing: no connection to \(host) port \(port) (\(String(cString: strerror(errno)))).", inputSent: .none)
        }
        descriptor = connected
    }

    deinit { Darwin.close(descriptor) }

    /// A longer deadline for the one read that waits for a person.
    func setReadDeadline(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw CommandFailure(.transportFailed, "Remote pairing: the connection ended while sending.", inputSent: .none) }
            sent += count
        }
    }

    func read(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count), filled = 0
        while filled < count {
            let got = buffer[filled...].withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard got > 0 else { throw CommandFailure(.transportFailed, "Remote pairing: the device ended the connection or did not answer in time.", inputSent: .none) }
            filled += got
        }
        return buffer
    }
}
