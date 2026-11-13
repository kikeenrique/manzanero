import AppleDeviceBridge
import CoreFoundation
import Foundation

/// Structural inspection only. PropertyListSerialization parses data; no
/// NSKeyedUnarchiver or device-specified Objective-C class is instantiated.
struct KeyedArchiveInspector {
    static let maximumBytes = 16 * 1024 * 1024
    private(set) var archives = 0
    private(set) var values = 0
    private var expandedBytes = 0

    static func inspect(_ bytes: Data) throws -> Data {
        var decoder = Self()
        let decoded = try decoder.archive(bytes, depth: 0)
        return try JSONSerialization.data(withJSONObject: [
            "format": "decoded-nskeyedarchive", "experimental": true, "parsedHierarchy": false,
            "decoded": decoded, "statistics": ["archives": decoder.archives, "expandedValues": decoder.values],
            "limitations": ["Structural decoding only; numeric accessibility attribute meanings and hierarchy semantics are not established.",
                "Opaque data is represented by byte counts. No selector-targetable tree or stable element references are produced."]
        ], options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    static func inspectFile(_ path: String) throws -> Data {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= maximumBytes {
            let chunk = try file.read(upToCount: maximumBytes + 1 - bytes.count) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        return try inspect(bytes)
    }

    private static func invalid(_ reason: String) -> CommandFailure {
        CommandFailure(description: "Invalid accessibility keyed archive: \(reason)")
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

    private mutating func archive(_ bytes: Data, depth: Int) throws -> Any {
        guard bytes.count <= Self.maximumBytes, depth <= 64, archives < 4 else {
            throw Self.invalid("archive byte, depth or nesting limit exceeded")
        }
        archives += 1
        try Self.validateBinaryUIDs(bytes)
        let parsed = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        guard let envelope = parsed as? [String: Any], envelope["$archiver"] as? String == "NSKeyedArchiver",
              let objects = envelope["$objects"] as? [Any], objects.count <= 100_000,
              let top = envelope["$top"] as? [String: Any], let root = top["root"], try uid(root) != nil else {
            throw Self.invalid("missing archiver, bounded object table or root reference")
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

    private mutating func value(_ item: Any, objects: [Any], stack: Set<Int>, depth: Int) throws -> Any {
        values += 1
        guard values <= 100_000, depth <= 64 else { throw Self.invalid("value or depth limit exceeded") }
        if let index = try uid(item) {
            guard objects.indices.contains(index), !stack.contains(index) else { throw Self.invalid("cyclic or out-of-range reference") }
            if index == 0, objects[index] as? String == "$null" { return NSNull() }
            return try value(objects[index], objects: objects, stack: stack.union([index]), depth: depth + 1)
        }
        if let string = item as? String { try charge(string.utf8.count); return string }
        if let number = item as? NSNumber {
            guard number.doubleValue.isFinite else { throw Self.invalid("non-finite number") }
            return number
        }
        if let date = item as? Date { return ["$date": ISO8601DateFormatter().string(from: date)] }
        if let bytes = item as? Data {
            if bytes.starts(with: Data("bplist00".utf8)) || bytes.starts(with: Data("<?xml".utf8)) {
                return ["byteCount": bytes.count, "nestedArchive": try archive(bytes, depth: depth + 1)] as [String: Any]
            }
            return ["dataBytes": bytes.count]
        }
        if let array = item as? [Any] {
            return try array.map { try value($0, objects: objects, stack: stack, depth: depth + 1) }
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
            return try value(stored, objects: objects, stack: stack, depth: depth + 1)
        }
        if ["NSDictionary", "NSMutableDictionary", "__NSDictionaryI", "__NSDictionaryM"].contains(className) {
            guard let keys = fields["NS.keys"] as? [Any], let entries = fields["NS.objects"] as? [Any], keys.count == entries.count else {
                throw Self.invalid("dictionary key/value count mismatch")
            }
            var result: [String: Any] = [:]
            for (key, entry) in zip(keys, entries) {
                let decoded = try value(key, objects: objects, stack: stack, depth: depth + 1)
                let text: String
                if let string = decoded as? String { text = string }
                else if let number = decoded as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
                else { throw Self.invalid("unsupported dictionary key") }
                try charge(text.utf8.count)
                guard result[text] == nil else { throw Self.invalid("duplicate decoded dictionary key") }
                result[text] = try value(entry, objects: objects, stack: stack, depth: depth + 1)
            }
            return result
        }
        var decoded: [String: Any] = [:]
        for (key, item) in fields where key != "$class" {
            try charge(key.utf8.count)
            decoded[key] = try value(item, objects: objects, stack: stack, depth: depth + 1)
        }
        try charge(className.utf8.count)
        return ["className": className, "fields": decoded] as [String: Any]
    }
}
