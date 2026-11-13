import Foundation

/// Data-only archive values, safe to carry across concurrency boundaries.
/// Native archive class names remain metadata rather than runtime classes.
indirect enum AccessibilityArchiveValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(String)
    case array([Self])
    case dictionary([String: Self])
    case object(className: String, fields: [String: Self])
    case nestedArchive(byteCount: Int, value: Self)

    var unsignedInteger: UInt64? {
        switch self {
        case .unsigned(let value): return value
        case .signed(let value): return UInt64(exactly: value)
        default: return nil
        }
    }

    var dictionaryKey: String? {
        switch self {
        case .string(let value): return value
        case .signed(let value): return String(value)
        case .unsigned(let value): return String(value)
        case .real(let value): return NSNumber(value: value).stringValue
        default: return nil
        }
    }

    /// Public offline inspection deliberately omits opaque bytes.
    var inspectionObject: Any {
        switch self {
        case .null: return NSNull()
        case .boolean(let value): return value
        case .signed(let value): return NSNumber(value: value)
        case .unsigned(let value): return NSNumber(value: value)
        case .real(let value): return value
        case .string(let value): return value
        case .data(let value): return ["dataBytes": value.count]
        case .date(let value): return ["$date": value]
        case .array(let values): return values.map(\.inspectionObject)
        case .dictionary(let values): return values.mapValues(\.inspectionObject)
        case .object(let name, let fields): return ["className": name, "fields": fields.mapValues(\.inspectionObject)] as [String: Any]
        case .nestedArchive(let count, let value): return ["byteCount": count, "nestedArchive": value.inspectionObject] as [String: Any]
        }
    }
}
