import Darwin
import Foundation
import Synchronization

/// Host-wide ownership of one physical device's input and media streams.
///
/// Two controllers sending contacts, keys or stream requests to the same device
/// corrupt each other's gestures and cleanup. A lease is an advisory `flock` on
/// a per-device file, so it is released by the kernel when the owning process
/// exits for any reason, including a crash or SIGKILL. Within one process the
/// lease is shared and counted, because one MCP server legitimately records and
/// sends input at the same time. Read-only observations do not take a lease.
///
/// A lease proves host-side exclusivity only. It says nothing about contacts or
/// streams that an earlier owner left active on the device.
final class DeviceLeaseRegistry: Sendable {
    static let shared = DeviceLeaseRegistry(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("manzanero/leases", isDirectory: true)
    }

    private struct Entry {
        let descriptor: Int32
        var holders: Int
    }

    private let directory: URL
    private let entries = Mutex<[String: Entry]>([:])

    init(directory: URL) {
        self.directory = directory
    }

    /// Takes or shares the lease for `device`, the resolved CoreDevice
    /// identifier (so every alias of one device maps to one lease). Never waits:
    /// a lease held by another process fails immediately and names its holder.
    func acquire(device: String, operation: String) throws -> DeviceLease {
        let key = try Self.key(device)
        try entries.withLock { entries in
            if var entry = entries[key] {
                entry.holders += 1
                entries[key] = entry
                return
            }
            entries[key] = Entry(descriptor: try open(key: key, operation: operation), holders: 1)
        }
        return DeviceLease(registry: self, key: key)
    }

    fileprivate func release(key: String) {
        entries.withLock { entries in
            guard var entry = entries[key] else { return }
            entry.holders -= 1
            if entry.holders > 0 {
                entries[key] = entry
                return
            }
            entries[key] = nil
            // Clear the holder note before unlocking so a later reader never
            // attributes the device to a process that has released it.
            _ = ftruncate(entry.descriptor, 0)
            _ = flock(entry.descriptor, LOCK_UN)
            _ = close(entry.descriptor)
        }
    }

    /// Device identifiers are hexadecimal with hyphens. Anything else, such as
    /// a device name, is refused rather than turned into a file name.
    static func key(_ device: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        guard (8...64).contains(device.utf8.count), device.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CommandFailure(description: "Device ownership requires a resolved device identifier; no input sent.")
        }
        return device.uppercased()
    }

    private func open(key: String, operation: String) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CommandFailure(description: "Cannot prepare the device ownership directory: \(error.localizedDescription). No input sent.")
        }
        let path = directory.appendingPathComponent("\(key).lock").path
        // The file is never unlinked by this code, but a person or cleanup tool
        // may remove it. A lock on a removed file excludes nobody, so retry
        // until the locked descriptor is the file currently at the path.
        for _ in 0..<8 {
            let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw CommandFailure(description: "Cannot open the device ownership file (\(String(cString: strerror(errno)))). No input sent.")
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                let holder = Self.readHolder(descriptor)
                _ = close(descriptor)
                guard code == EWOULDBLOCK else {
                    throw CommandFailure(description: "Cannot take device ownership (\(String(cString: strerror(code)))). No input sent.")
                }
                throw CommandFailure(description: "Device is controlled by another manzanero process\(holder.map { " (\($0))" } ?? ""). Wait for it to finish or stop it; no input sent.")
            }
            var held = stat(), current = stat()
            if fstat(descriptor, &held) == 0, stat(path, &current) == 0,
               held.st_ino == current.st_ino, held.st_dev == current.st_dev {
                Self.writeHolder(descriptor, operation: operation)
                return descriptor
            }
            _ = close(descriptor)
        }
        throw CommandFailure(description: "The device ownership file kept changing; no input sent.")
    }

    private static func writeHolder(_ descriptor: Int32, operation: String) {
        let note = "pid \(getpid()), \(operation.prefix(64))\n"
        _ = ftruncate(descriptor, 0)
        _ = note.withCString { pwrite(descriptor, $0, strlen($0), 0) }
    }

    /// Diagnostic only: the note can be stale or mid-write, and is sanitized
    /// because it is echoed into an error message.
    private static func readHolder(_ descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || " ,-".unicodeScalars.contains($0)) }
        let note = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? nil : note
    }
}

/// One holder's share of a device lease. Released explicitly or on deinit.
final class DeviceLease: Sendable {
    private let registry: DeviceLeaseRegistry
    private let key: String
    private let released = Mutex(false)

    fileprivate init(registry: DeviceLeaseRegistry, key: String) {
        self.registry = registry
        self.key = key
    }

    func release() {
        let first = released.withLock { done in
            defer { done = true }
            return !done
        }
        if first { registry.release(key: key) }
    }

    deinit { release() }
}
