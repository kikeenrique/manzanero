import AppleDeviceBridge
import CoreFoundation
import Foundation

/// Bounded data-only decoding. PropertyListSerialization parses data; no
/// NSKeyedUnarchiver or device-specified Objective-C class is instantiated.
struct KeyedArchiveInspector {
    static let maximumBytes = 16 * 1024 * 1024
    private(set) var archives = 0
    private(set) var values = 0
    private var expandedBytes = 0
    private var inspectNestedArchives = true
    private var responseTypeOnly = false
    private var maximumDepth: Int { inspectNestedArchives ? 64 : 512 }

    static func inspect(_ bytes: Data) throws -> Data {
        var decoder = Self()
        let decoded = try decoder.archive(bytes, depth: 0)
        return try JSONSerialization.data(withJSONObject: [
            "format": "decoded-nskeyedarchive", "experimental": true, "parsedHierarchy": false,
            "decoded": decoded.inspectionObject, "statistics": ["archives": decoder.archives, "expandedValues": decoder.values],
            "limitations": ["Structural decoding only; numeric accessibility attribute meanings and hierarchy semantics are not established.",
                "Opaque data is represented by byte counts. No selector-targetable tree or stable element references are produced."]
        ], options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    /// Internal protocol decoding preserves opaque token bytes. Only a root
    /// NSData callback envelope is unwrapped; token data resembling a plist
    /// must not be interpreted as another archive.
    static func decodeProtocol(_ bytes: Data) throws -> AccessibilityArchiveValue {
        var decoder = Self()
        decoder.inspectNestedArchives = false
        let root = try decoder.archive(bytes, depth: 0)
        if case .data(let nested) = root {
            return try decoder.archive(nested, depth: 1)
        }
        return root
    }

    /// Read only the semantic envelope's request type before expanding result
    /// data. Unrelated notifications can contain values unsupported by our
    /// requested read schema (including NaN); they must never satisfy a read.
    static func protocolResponseType(_ bytes: Data) throws -> UInt64 {
        var decoder = Self()
        decoder.inspectNestedArchives = false
        decoder.responseTypeOnly = true
        var value = try decoder.archive(bytes, depth: 0)
        if case .data(let nested) = value { value = try decoder.archive(nested, depth: 1) }
        guard case .object("AXPTranslatorResponse", let fields) = value,
              let kind = fields["associatedRequestType"]?.unsignedInteger else {
            throw invalid("missing response class or typed request type")
        }
        return kind
    }

    /// `decode-ax-archive`: the archive is the caller's file, so a file that
    /// cannot be read or is not a valid archive is a usage error.
    static func inspectFile(_ path: String) throws -> Data {
        var bytes = Data()
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            while bytes.count <= maximumBytes {
                let chunk = try file.read(upToCount: maximumBytes + 1 - bytes.count) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
        } catch {
            throw CommandFailure.usage("Archive is not readable: \(path) (\(error.localizedDescription))")
        }
        do {
            return try inspect(bytes)
        } catch let failure as CommandFailure where failure.code == .transportFailed {
            throw CommandFailure.usage(failure.description)
        }
    }

    /// An archive that is not what the protocol sends. Archives decoded here
    /// are device or simulator replies, so this is a malformed reply; the
    /// offline `inspectFile` turns it into a usage error. Whether input was
    /// sent is not known here; the accessibility paths refine it by stage.
    private static func invalid(_ reason: String) -> CommandFailure {
        CommandFailure(.transportFailed, "Invalid accessibility keyed archive: \(reason)", inputSent: .unknown)
    }

    private func uid(_ value: Any) throws -> Int? {
        let object = value as AnyObject
        var index: UInt64 = 0
        let status = ADCReadArchiveUID(Unmanaged.passUnretained(object).toOpaque(), &index)
        guard status >= 0 else { throw Self.invalid("Apple UID reader unavailable") }
        if status == 0 { return nil }
        guard let index = Int(exactly: index) else { throw Self.invalid("reference overflow") }
        return index
    }

    private mutating func charge(_ count: Int) throws {
        guard count <= Self.maximumBytes * 2 - expandedBytes else { throw Self.invalid("expanded byte limit exceeded") }
        expandedBytes += count
    }

    private mutating func archive(_ bytes: Data, depth: Int) throws -> AccessibilityArchiveValue {
        guard bytes.count <= Self.maximumBytes, depth <= maximumDepth, archives < 4 else {
            throw Self.invalid("archive byte, depth or nesting limit exceeded")
        }
        archives += 1
        try Self.validateBinaryUIDs(bytes)
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        } catch {
            throw Self.invalid("not a property list (\(error.localizedDescription))")
        }
        guard let envelope = parsed as? [String: Any], envelope["$archiver"] as? String == "NSKeyedArchiver",
              let table = envelope["$objects"] as? [Any], table.count <= 100_000,
              let top = envelope["$top"] as? [String: Any], let root = top["root"], try uid(root) != nil else {
            throw Self.invalid("missing archiver, bounded object table or root reference")
        }
        var objects = table
        if responseTypeOnly, let index = try uid(root), objects.indices.contains(index),
           let fields = objects[index] as? [String: Any], let reference = fields["$class"],
           let classIndex = try uid(reference), objects.indices.contains(classIndex),
           let metadata = objects[classIndex] as? [String: Any], metadata["$classname"] as? String == "AXPTranslatorResponse" {
            objects[index] = fields.filter { ["$class", "associatedRequestType"].contains($0.key) }
        }
        return try value(root, objects: objects, stack: [], depth: depth + 1)
    }

    /// Foundation's UID accessor exposes a 32-bit value. Check original binary
    /// UID scalars before parsing so a wider wire value cannot alias a valid ID.
    private static func validateBinaryUIDs(_ bytes: Data) throws {
        guard bytes.starts(with: Data("bplist00".utf8)) else { return }
        guard bytes.count >= 40 else { throw invalid("short binary plist") }
        func integer(_ offset: Int, _ count: Int) -> UInt64 {
            bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let trailer = bytes.count - 32
        let width = Int(bytes[trailer + 6])
        let count = integer(trailer + 8, 8), table = integer(trailer + 24, 8)
        guard (1...8).contains(width), count <= 1_000_000, table >= 8, table <= UInt64(trailer),
              count <= (UInt64(trailer) - table) / UInt64(width) else { throw invalid("binary offset table bounds") }
        for index in 0..<Int(count) {
            let offset = integer(Int(table) + index * width, width)
            guard offset >= 8, offset < table else { throw invalid("binary object offset") }
            let marker = bytes[Int(offset)]
            if marker >> 4 == 8 {
                let size = Int(marker & 15) + 1
                guard size <= 8, UInt64(size) < table - offset,
                      integer(Int(offset) + 1, size) < 100_000 else { throw invalid("UID value or width limit exceeded") }
            }
        }
    }

    private mutating func value(_ item: Any, objects: [Any], stack: Set<Int>, depth: Int) throws -> AccessibilityArchiveValue {
        enum Work {
            case visit(Any, Set<Int>, Int)
            case array(Int)
            case dictionary(Int)
            case object(String, [String])
        }
        var work: [Work] = [.visit(item, stack, depth)]
        var output: [AccessibilityArchiveValue] = []
        while let next = work.popLast() {
            switch next {
            case .array(let count):
                let entries = Array(output.suffix(count))
                output.removeLast(count)
                output.append(.array(entries))
            case .dictionary(let count):
                let entries = Array(output.suffix(count * 2))
                output.removeLast(count * 2)
                var result: [String: AccessibilityArchiveValue] = [:]
                for index in 0..<count {
                    guard let key = entries[index * 2].dictionaryKey else { throw Self.invalid("unsupported dictionary key") }
                    try charge(key.utf8.count)
                    guard result[key] == nil else { throw Self.invalid("duplicate decoded dictionary key") }
                    result[key] = entries[index * 2 + 1]
                }
                output.append(.dictionary(result))
            case .object(let name, let keys):
                let entries = Array(output.suffix(keys.count))
                output.removeLast(keys.count)
                output.append(.object(className: name, fields: Dictionary(uniqueKeysWithValues: zip(keys, entries))))
            case .visit(let item, let stack, let depth):
                values += 1
                guard values <= 100_000, depth <= maximumDepth else { throw Self.invalid("value or depth limit exceeded") }
                if let index = try uid(item) {
                    guard objects.indices.contains(index), !stack.contains(index) else { throw Self.invalid("cyclic or out-of-range reference") }
                    if index == 0, objects[index] as? String == "$null" { output.append(.null) }
                    else { work.append(.visit(objects[index], stack.union([index]), depth + 1)) }
                    continue
                }
                if let string = item as? String { try charge(string.utf8.count); output.append(.string(string)); continue }
                if let number = item as? NSNumber {
                    guard number.doubleValue.isFinite else { throw Self.invalid("non-finite number") }
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { output.append(.boolean(number.boolValue)) }
                    else {
                        switch String(cString: number.objCType) {
                        case "f", "d": output.append(.real(number.doubleValue))
                        case "Q", "L", "I", "S", "C": output.append(.unsigned(number.uint64Value))
                        default: output.append(.signed(number.int64Value))
                        }
                    }
                    continue
                }
                if let date = item as? Date { output.append(.date(ISO8601DateFormatter().string(from: date))); continue }
                if let bytes = item as? Data {
                    if inspectNestedArchives && (bytes.starts(with: Data("bplist00".utf8)) || bytes.starts(with: Data("<?xml".utf8))) {
                        output.append(.nestedArchive(byteCount: bytes.count, value: try archive(bytes, depth: depth + 1)))
                    } else { try charge(bytes.count); output.append(.data(bytes)) }
                    continue
                }
                if let array = item as? [Any] {
                    guard array.count < 100_000 - work.count else { throw Self.invalid("pending work limit exceeded") }
                    work.append(.array(array.count))
                    for item in array.reversed() { work.append(.visit(item, stack, depth + 1)) }
                    continue
                }
                guard let fields = item as? [String: Any] else { throw Self.invalid("unsupported property-list value") }
                var className = ""
                if let reference = fields["$class"] {
                    guard let index = try uid(reference), objects.indices.contains(index),
                          let metadata = objects[index] as? [String: Any], let name = metadata["$classname"] as? String else {
                        throw Self.invalid("class reference or description")
                    }
                    className = name
                }
                let storageKey: String?
                switch className {
                case "NSData", "NSMutableData", "__NSCFData": storageKey = "NS.data"
                case "NSString", "NSMutableString", "__NSCFString": storageKey = "NS.string"
                case "NSArray", "NSMutableArray", "__NSArrayI", "__NSArrayM", "NSSet", "NSMutableSet": storageKey = "NS.objects"
                default: storageKey = nil
                }
                if let storageKey {
                    guard let stored = fields[storageKey] else { throw Self.invalid("missing \(storageKey)") }
                    work.append(.visit(stored, stack, depth + 1))
                } else if ["NSDictionary", "NSMutableDictionary", "__NSDictionaryI", "__NSDictionaryM"].contains(className) {
                    guard let keys = fields["NS.keys"] as? [Any], let entries = fields["NS.objects"] as? [Any], keys.count == entries.count else {
                        throw Self.invalid("dictionary key/value count mismatch")
                    }
                    guard keys.count < (100_000 - work.count) / 2 else { throw Self.invalid("pending work limit exceeded") }
                    work.append(.dictionary(keys.count))
                    for (key, entry) in zip(keys, entries).reversed() {
                        work.append(.visit(entry, stack, depth + 1))
                        work.append(.visit(key, stack, depth + 1))
                    }
                } else {
                    let keys = fields.keys.filter { $0 != "$class" }.sorted()
                    guard keys.count < 100_000 - work.count else { throw Self.invalid("pending work limit exceeded") }
                    try charge(className.utf8.count)
                    work.append(.object(className, keys))
                    for key in keys.reversed() {
                        try charge(key.utf8.count)
                        work.append(.visit(fields[key]!, stack, depth + 1))
                    }
                }
            }
        }
        guard output.count == 1, let result = output.first else { throw Self.invalid("incomplete value assembly") }
        return result
    }
}
