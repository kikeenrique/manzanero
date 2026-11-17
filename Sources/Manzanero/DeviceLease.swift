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
///
/// Quarantine covers the part of that the host can know. A device is marked
/// when an input ended with an unknown outcome (`markUncertain`), or when a
/// new owner finds the note of an input owner that exited without releasing
/// (a crash, SIGKILL or forced exit: a normal release clears the note). The
/// mark is a `<device>.quarantine` file beside the lock; while it exists,
/// every operation that sends input is refused, in this and in other
/// processes, until `clearQuarantine`. Nothing is sent to the device for it:
/// whether a contact is really still down there is not known.
final class DeviceLeaseRegistry: Sendable {
    /// Owners that hold a stream, not contacts or keys. Their unclean exit
    /// does not quarantine the device, and quarantine does not refuse them.
    static let streamOperations = ["record", "frames"]

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
        let sendsInput = !Self.streamOperations.contains(operation)
        try entries.withLock { entries in
            if var entry = entries[key] {
                if sendsInput, let note = quarantineNote(key) { throw Self.quarantined(note) }
                entry.holders += 1
                entries[key] = entry
                return
            }
            // Opening the lock is what finds an owner that died holding it,
            // so the quarantine check comes after it.
            let descriptor = try open(key: key, operation: operation)
            if sendsInput, let note = quarantineNote(key) {
                Self.unlock(descriptor)
                throw Self.quarantined(note)
            }
            entries[key] = Entry(descriptor: descriptor, holders: 1)
        }
        return DeviceLease(registry: self, key: key)
    }

    /// Marks `device` after an input whose release is unknown. Returns false
    /// when the mark could not be written.
    @discardableResult
    func markUncertain(device: String, reason: String) -> Bool {
        guard let key = try? Self.key(device) else { return false }
        return mark(key, reason: reason)
    }

    /// Why `device` is quarantined, or nil when it is not.
    func quarantine(device: String) throws -> String? {
        let key = try Self.key(device)
        adoptAbandonedOwner(key)
        return quarantineNote(key)
    }

    /// An owner that died holding the lock is otherwise found only by the
    /// next owner. This finds it without becoming one: if the lock is free
    /// and still carries an input owner's note, the device is marked and the
    /// note cleared. A lock held by anyone, this process included, is left alone.
    private func adoptAbandonedOwner(_ key: String) {
        entries.withLock { entries in
            guard entries[key] == nil else { return }
            let descriptor = Darwin.open(directory.appendingPathComponent("\(key).lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { _ = close(descriptor); return }
            if let stale = Self.readHolder(descriptor), !Self.streamOperations.contains(where: { stale.hasSuffix(", \($0)") }) {
                _ = mark(key, reason: "the previous owner (\(stale)) exited without releasing the device")
            }
            Self.unlock(descriptor)
        }
    }

    /// Removes the mark and returns what it said, or nil when there was none.
    /// It sends nothing to the device: the caller has inspected it.
    func clearQuarantine(device: String) throws -> String? {
        let key = try Self.key(device)
        adoptAbandonedOwner(key)
        guard let note = quarantineNote(key) else { return nil }
        do {
            try FileManager.default.removeItem(at: quarantineFile(key))
        } catch {
            throw CommandFailure(.hostRequirement, "Cannot remove the device quarantine mark: \(error.localizedDescription).", inputSent: .none)
        }
        return note
    }

    private static func quarantined(_ note: String) -> CommandFailure {
        CommandFailure(.deviceQuarantined, "Device is quarantined: \(note). A contact, key or button may still be held on it. Inspect it (tree, screenshot), then run clear-quarantine for this device; no input sent.", inputSent: .none)
    }

    private func quarantineFile(_ key: String) -> URL { directory.appendingPathComponent("\(key).quarantine") }

    /// The mark's text, sanitized because it is echoed into messages.
    private func quarantineNote(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: quarantineFile(key)) else { return nil }
        let text = String(decoding: data.prefix(400), as: UTF8.self).unicodeScalars
            .filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
        let note = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? "no reason recorded" : note
    }

    /// The first reason is kept: a later one would hide when it began.
    private func mark(_ key: String, reason: String) -> Bool {
        if quarantineNote(key) != nil { return true }
        let note = "\(reason.prefix(300)), since \(ISO8601DateFormatter().string(from: Date()))\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(note.utf8).write(to: quarantineFile(key), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func unlock(_ descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
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
            // attributes the device to a process that has released it, and
            // so a note still present means its writer did not get here.
            Self.unlock(entry.descriptor)
        }
    }

    /// Device identifiers are hexadecimal with hyphens. Anything else, such as
    /// a device name, is refused rather than turned into a file name.
    static func key(_ device: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        guard (8...64).contains(device.utf8.count), device.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CommandFailure(.internal, "Device ownership requires a resolved device identifier; no input sent.", inputSent: .none)
        }
        return device.uppercased()
    }

    private func open(key: String, operation: String) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CommandFailure(.hostRequirement, "Cannot prepare the device ownership directory: \(error.localizedDescription). No input sent.", inputSent: .none)
        }
        let path = directory.appendingPathComponent("\(key).lock").path
        // The file is never unlinked by this code, but a person or cleanup tool
        // may remove it. A lock on a removed file excludes nobody, so retry
        // until the locked descriptor is the file currently at the path.
        for _ in 0..<8 {
            let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw CommandFailure(.hostRequirement, "Cannot open the device ownership file (\(String(cString: strerror(errno)))). No input sent.", inputSent: .none)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                let holder = Self.readHolder(descriptor)
                _ = close(descriptor)
                guard code == EWOULDBLOCK else {
                    throw CommandFailure(.hostRequirement, "Cannot take device ownership (\(String(cString: strerror(code)))). No input sent.", inputSent: .none)
                }
                throw CommandFailure(.deviceBusy, "Device is controlled by another manzanero process\(holder.map { " (\($0))" } ?? ""). Wait for it to finish or stop it; no input sent.", inputSent: .none)
            }
            var held = stat(), current = stat()
            if fstat(descriptor, &held) == 0, stat(path, &current) == 0,
               held.st_ino == current.st_ino, held.st_dev == current.st_dev {
                // A note under a free lock was left by an owner that exited
                // without releasing. If it was sending input, its contacts,
                // keys or buttons may still be held.
                if let stale = Self.readHolder(descriptor),
                   !Self.streamOperations.contains(where: { stale.hasSuffix(", \($0)") }) {
                    _ = mark(key, reason: "the previous owner (\(stale)) exited without releasing the device")
                }
                Self.writeHolder(descriptor, operation: operation)
                return descriptor
            }
            _ = close(descriptor)
        }
        throw CommandFailure(.deviceBusy, "The device ownership file kept changing; no input sent.", inputSent: .none)
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
