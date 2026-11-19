import Foundation

/// The accessibility service's port on each tunnel whose service directory
/// has already been read, by this process or by an earlier one.
///
/// Reading the directory is what disturbs the Mac's `remoted`: the device
/// resets `remoted`'s own directory connection when the tool's arrives, and
/// now and then `remoted` never reconnects (docs/transport.md#the-cost-of-this-route).
/// The port the directory gives does not change while the tunnel lives, so
/// the directory is read once per tunnel and later commands connect straight
/// to the port: in the same process from memory, in another process from a
/// small file. A new tunnel has a new address, so its entry is never found.
final class AccessibilityServicePorts: @unchecked Sendable {
    /// Kept beside the device leases, for the user only.
    static let shared = AccessibilityServicePorts(file: DeviceLeaseRegistry.defaultDirectory
        .deletingLastPathComponent().appendingPathComponent("service-ports.json"))

    /// An entry older than this is not used: tunnels rarely live so long,
    /// and a wrong port costs one failed command.
    static let maximumAge: TimeInterval = 12 * 60 * 60
    static let maximumEntries = 64
    static let maximumFileBytes = 64 * 1024

    struct Entry: Codable, Equatable {
        var port: UInt16
        var saved: Date
    }

    private let lock = NSLock()
    private var ports: [String: Entry] = [:]
    private let file: URL?
    private let now: @Sendable () -> Date

    /// `file` nil keeps the ports in memory only.
    init(file: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.now = now
    }

    private func key(_ device: String, _ tunnelAddress: String) -> String { "\(device)|\(tunnelAddress)" }

    private func fresh(_ entry: Entry?) -> UInt16? {
        guard let entry, entry.port > 0, abs(now().timeIntervalSince(entry.saved)) <= Self.maximumAge else { return nil }
        return entry.port
    }

    /// What the file holds; anything unreadable, oversized or malformed is
    /// no entries.
    private func stored() -> [String: Entry] {
        guard let file, let data = try? Data(contentsOf: file), data.count <= Self.maximumFileBytes,
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    /// Replaces the file with the fresh entries, the newest kept when there
    /// are too many. A failure to write is not an error: the port is then
    /// read from the directory again.
    private func store(_ entries: [String: Entry]) {
        guard let file else { return }
        let kept = entries.filter { fresh($0.value) != nil }.sorted { $0.value.saved > $1.value.saved }.prefix(Self.maximumEntries)
        guard let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The remembered port and whether it came from this process's memory
    /// or from the file another process wrote.
    func port(device: String, tunnelAddress: String) -> (port: UInt16, source: String)? {
        lock.withLock {
            let key = key(device, tunnelAddress)
            if let port = fresh(ports[key]) { return (port, "reused-port") }
            guard let entry = stored()[key], let port = fresh(entry) else { return nil }
            ports[key] = entry
            return (port, "reused-saved-port")
        }
    }

    func remember(_ port: UInt16, device: String, tunnelAddress: String) {
        lock.withLock {
            let entry = Entry(port: port, saved: now())
            ports[key(device, tunnelAddress)] = entry
            var entries = stored()
            entries[key(device, tunnelAddress)] = entry
            store(entries)
        }
    }

    func forget(device: String, tunnelAddress: String) {
        lock.withLock {
            ports[key(device, tunnelAddress)] = nil
            var entries = stored()
            guard entries.removeValue(forKey: key(device, tunnelAddress)) != nil else { return }
            store(entries)
        }
    }

    /// Whether a failure leaves the remembered port in doubt. A selector
    /// that matched nothing, or a display that is off, was answered by the
    /// service; a transport error or a timeout may mean the port is wrong.
    static func doubts(_ error: any Error) -> Bool {
        guard let failure = error as? CommandFailure else { return true }
        switch failure.code {
        case .targetUnresolved, .preconditionChanged, .usage, .displayOff, .unsupportedOperation, .inputOutcomeUnknown, .cancelled: return false
        default: return true
        }
    }
}
