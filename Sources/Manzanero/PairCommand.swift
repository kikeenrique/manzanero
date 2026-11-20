import dnssd
import Foundation

/// `pair`: a pairing of the tool's own with a device, for a tunnel of the
/// tool's own to a device the Mac's usbmuxd does not list, which is an
/// Apple TV (docs/transport.md#a-pairing-of-the-tools-own). It is Apple's
/// newer pairing, the one Xcode makes: the device shows a PIN, and from then
/// on lists a host named `manzanero`. The identity is kept on this Mac, in a
/// file only its owner can read.
struct PairCommand: Equatable, Sendable {
    static let operation = "pair"
    let device: String
    /// A file the PIN is read from once it is there; without it the PIN is
    /// asked for at the terminal.
    var pinFile: String?
    /// Remove this Mac's identity for the device instead of pairing.
    var forget = false

    static let pinWaitSeconds = 180
    static let screenHint = "On an Apple TV, open Settings > Remotes and Devices > Remote App and Devices and leave that screen open: it accepts a new pairing only there."

    func plan() -> [String: Any] {
        ["backend": "remote-pairing", "operation": Self.operation, "device": device, "forget": forget,
         "pinSource": pinFile.map { "file \($0), waited for up to \(Self.pinWaitSeconds) seconds" } ?? "the terminal",
         "hostName": RemotePairingClient.hostName,
         "liveVerification": "one Apple TV 4K (3rd generation), tvOS 27.2",
         "execution": forget
            ? "Delete this Mac's pairing identity for the device. Nothing is sent to the device, which keeps the host in its list until it is removed there."
            : "Read the device's details for its hardware identifier, its name and its address. If a stored identity is still known to the device (pair-verify at its pairing service), stop there. Otherwise find the manual-pairing service the device advertises while its pairing screen is open, start a pairing there, take the PIN the device shows, finish the pairing and store the identity; then verify it on a new connection. No input is sent to the device."]
    }

    /// What the command reads from the device's details.
    struct Subject: Equatable {
        let udid: String
        let name: String
        let address: String
    }

    static func subject(details: Data, requested: String) throws -> Subject {
        // The name is in `state` in the current shape of the details and in
        // `deviceProperties` in the one it replaces.
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any], let result = root["result"] as? [String: Any],
              let properties = result["properties"] as? [String: Any],
              let udid = (properties["hardware"] as? [String: Any])?["udid"] as? String,
              let name = [properties["state"], properties["deviceProperties"], result["deviceProperties"]]
                  .lazy.compactMap({ ($0 as? [String: Any])?["name"] as? String }).first else {
            throw CommandFailure(.deviceNotReady, "pair needs the device's details with its hardware identifier and name; nothing was contacted.", inputSent: .none)
        }
        return Subject(udid: udid, name: name, address: try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid))
    }

    /// How the command reaches things; tests replace all of it.
    struct Environment {
        var identities: URL = PairingIdentity.directory
        var connect: (_ host: String, _ port: UInt16) throws -> any PairingStream = { try PairingSocket(host: $0, port: $1, seconds: 200) }
        var manualPairingPort: (_ deviceName: String) throws -> UInt16? = PairingDiscovery.manualPairingPort
        var pin: (PairCommand) throws -> String = PairCommand.readPIN
    }

    func execute(details: Data, environment: Environment = Environment()) throws -> Data {
        let subject = try Self.subject(details: details, requested: device)
        var result: [String: Any] = ["backend": "remote-pairing", "operation": Self.operation, "device": device, "hostName": RemotePairingClient.hostName]
        func finish(_ status: String, _ note: String) throws -> Data {
            result["status"] = status
            result["note"] = note
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        if forget {
            let file = PairingIdentity.file(udid: subject.udid, directory: environment.identities)
            guard FileManager.default.fileExists(atPath: file.path) else { return try finish("not-paired", "This Mac holds no pairing of the tool's own for the device.") }
            try FileManager.default.removeItem(at: file)
            return try finish("forgotten", "This Mac's identity for the device is deleted. The device still lists the host \(RemotePairingClient.hostName) until it is removed in the device's settings.")
        }
        func verified(_ identity: PairingIdentity) throws -> Bool {
            let client = RemotePairingClient(stream: try environment.connect(subject.address, DeviceTunnel.pairingPort))
            try client.handshake()
            return try client.verify(identity) && client.peerSignatureValid != false
        }
        if let stored = PairingIdentity.load(udid: subject.udid, directory: environment.identities), try verified(stored) {
            return try finish("already-paired", "The device knows this Mac's identity; nothing was changed.")
        }
        guard let port = try environment.manualPairingPort(subject.name) else {
            throw CommandFailure(.deviceNotReady, "The device does not advertise its manual-pairing service. \(Self.screenHint) Nothing was changed.", inputSent: .none)
        }
        var identity = PairingIdentity.generate()
        let client = RemotePairingClient(stream: try environment.connect(subject.address, port))
        try client.handshake()
        // An unknown identity is refused first; the pairing follows on the
        // same connection.
        guard try !client.verify(identity) else {
            throw CommandFailure(.internal, "The device accepted an identity it was never given.", inputSent: .none)
        }
        try client.setup(&identity) { try environment.pin(self) }
        try identity.save(udid: subject.udid, directory: environment.identities)
        guard try verified(identity) else {
            throw CommandFailure(.transportFailed, "The pairing finished and the device did not verify it on a new connection. The identity is stored; run pair again.", inputSent: .none)
        }
        return try finish("paired", "The device now lists the host \(RemotePairingClient.hostName), and accessibility commands for it use a tunnel of the tool's own.")
    }

    /// The PIN from the file named, once it holds six characters, or typed
    /// at the terminal.
    static func readPIN(_ command: PairCommand) throws -> String {
        if let pinFile = command.pinFile {
            FileHandle.standardError.write(Data("The device shows a PIN. Waiting up to \(pinWaitSeconds) seconds for it in \(pinFile).\n".utf8))
            for _ in 0..<pinWaitSeconds {
                try Task.checkCancellation()
                if let text = try? String(contentsOfFile: pinFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 6 { return text }
                Thread.sleep(forTimeInterval: 1)
            }
            throw CommandFailure(.timeout, "No PIN arrived in \(pinFile) within \(pinWaitSeconds) seconds; the pairing was abandoned.", inputSent: .none)
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CommandFailure.usage("pair asks for the PIN at a terminal; without one, give --pin-file <path> and write the PIN there once the device shows it.")
        }
        FileHandle.standardError.write(Data("PIN shown on the device: ".utf8))
        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), line.count >= 6 else {
            throw CommandFailure.usage("The pairing PIN has six digits.")
        }
        return line
    }
}

/// Finds the manual-pairing service a device advertises while its pairing
/// screen is open, through the Mac's mDNSResponder (the public DNS Service
/// Discovery interface). The port changes each time the screen is opened.
enum PairingDiscovery {
    static let serviceType = "_remotepairing-manual-pairing._tcp"

    private final class Found {
        var names: [String] = []
        var port: UInt16?
        var deviceName: String?
    }

    /// Runs one DNS-SD operation's callbacks for up to `seconds`.
    private static func process(_ reference: DNSServiceRef, seconds: Double, until done: () -> Bool) {
        let descriptor = DNSServiceRefSockFD(reference)
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            var readable = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&readable, 1, 200) > 0 { guard DNSServiceProcessResult(reference) == kDNSServiceErr_NoError else { return } }
        }
    }

    /// `name=…` in a TXT record.
    static func name(txt: [UInt8]) -> String? {
        var index = 0
        while index < txt.count {
            let length = Int(txt[index])
            guard index + 1 + length <= txt.count else { return nil }
            let entry = String(decoding: txt[(index + 1)..<(index + 1 + length)], as: UTF8.self)
            if entry.hasPrefix("name=") { return String(entry.dropFirst(5)) }
            index += 1 + length
        }
        return nil
    }

    /// The port of the manual-pairing service whose name is the device's,
    /// or nil when no such service is advertised within a few seconds.
    static func manualPairingPort(deviceName: String) throws -> UInt16? {
        let found = Found()
        let context = Unmanaged.passUnretained(found).toOpaque()
        var browse: DNSServiceRef?
        guard DNSServiceBrowse(&browse, 0, 0, serviceType, "local.", { _, flags, _, error, name, _, _, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name, let context else { return }
            Unmanaged<Found>.fromOpaque(context).takeUnretainedValue().names.append(String(cString: name))
        }, context) == kDNSServiceErr_NoError, let browse else {
            throw CommandFailure(.hostRequirement, "The Mac's DNS service discovery could not be asked for the device's pairing service.", inputSent: .none)
        }
        process(browse, seconds: 4) { found.names.contains(deviceName) }
        DNSServiceRefDeallocate(browse)
        for candidate in found.names {
            found.port = nil
            found.deviceName = nil
            var resolve: DNSServiceRef?
            guard DNSServiceResolve(&resolve, 0, 0, candidate, serviceType, "local.", { _, _, _, error, _, _, port, length, txt, context in
                guard error == kDNSServiceErr_NoError, let context else { return }
                let found = Unmanaged<Found>.fromOpaque(context).takeUnretainedValue()
                found.port = UInt16(bigEndian: port)
                found.deviceName = txt.flatMap { PairingDiscovery.name(txt: Array(UnsafeBufferPointer(start: $0, count: Int(length)))) }
            }, context) == kDNSServiceErr_NoError, let resolve else { continue }
            process(resolve, seconds: 3) { found.port != nil }
            DNSServiceRefDeallocate(resolve)
            if let port = found.port, candidate == deviceName || found.deviceName == deviceName { return port }
        }
        return nil
    }
}
