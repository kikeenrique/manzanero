import Foundation

/// Normalization of one native descendant snapshot. This does not select the
/// foreground app, prove root stability, or establish complete screen coverage.
enum AccessibilitySnapshot {
    enum Scalar: Encodable, Sendable, Equatable {
        case string(String), boolean(Bool), signed(Int64), unsigned(UInt64), real(Double)

        init(_ value: AccessibilityArchiveValue) throws {
            switch value {
            case .string(let value): self = .string(value)
            case .boolean(let value): self = .boolean(value)
            case .signed(let value): self = .signed(value)
            case .unsigned(let value): self = .unsigned(value)
            case .real(let value) where value.isFinite: self = .real(value)
            default: throw invalid("unsupported label/hint/identifier/value shape")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .signed(let value): try container.encode(value)
            case .unsigned(let value): try container.encode(value)
            case .real(let value): try container.encode(value)
            }
        }
    }

    struct Frame: Encodable, Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Node: Encodable, Sendable {
        let id: String
        let parentId: String?
        let depth: Int
        var children: [String] = []
        let attributeSource = "native-snapshot"
        var label: Scalar?
        var hint: Scalar?
        var identifier: Scalar?
        var value: Scalar?
        var frame: Frame?
        var frameUnavailable: String?
        var traits: String?
        var visible: Bool?
        var nativeAttributes: [String: String]?
        var processIdentifier: Int32?
        var externalProcessReference: Bool?
        // Fresh in-session identity, excluded from encoded agent observations.
        let token: AccessibilityRequest.Token

        enum CodingKeys: String, CodingKey {
            case id, parentId, depth, children, attributeSource, label, hint, identifier, value
            case frame, frameUnavailable, traits, visible, nativeAttributes, processIdentifier, externalProcessReference
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(depth, forKey: .depth)
            try container.encode(children, forKey: .children)
            try container.encode(attributeSource, forKey: .attributeSource)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(hint, forKey: .hint)
            try container.encodeIfPresent(identifier, forKey: .identifier)
            try container.encodeIfPresent(value, forKey: .value)
            try container.encodeIfPresent(frame, forKey: .frame)
            try container.encodeIfPresent(frameUnavailable, forKey: .frameUnavailable)
            try container.encodeIfPresent(traits, forKey: .traits)
            try container.encodeIfPresent(visible, forKey: .visible)
            try container.encodeIfPresent(nativeAttributes, forKey: .nativeAttributes)
            try container.encodeIfPresent(processIdentifier, forKey: .processIdentifier)
            try container.encodeIfPresent(externalProcessReference, forKey: .externalProcessReference)
        }
    }

    static func normalize(_ snapshot: AccessibilityArchiveValue, root: AccessibilityRequest.Token) throws -> [Node] {
        guard root.isApplicationElement else { throw invalid("expected root is not an application") }
        var pending: [(AccessibilityArchiveValue, Int?, Int)] = [(snapshot, nil, 0)]
        var cursor = 0
        var nodes: [Node] = []
        while cursor < pending.count {
            let (value, parent, depth) = pending[cursor]
            cursor += 1
            guard nodes.count < 512, depth <= 32, case .dictionary(let record) = value,
                  let element = record["UIAccessibilitySnapshotKeyElement"],
                  case .array(let children) = record["UIAccessibilitySnapshotKeyChildren"],
                  record["UIAccessibilitySnapshotKeyChildrenCount"]?.unsignedInteger == UInt64(children.count),
                  case .dictionary(let attributes) = record["UIAccessibilitySnapshotKeyAttributes"] else {
                throw invalid("node/depth limit or malformed record/children count")
            }
            let token = try AccessibilityResponse.token(element)
            if parent == nil {
                guard token.pid == root.pid, token.objectID == root.objectID, token.isApplicationElement else {
                    throw invalid("snapshot root identity mismatch")
                }
            }
            if token.pid != root.pid {
                guard attributes["5003"] == .string("AXRemoteElement"), children.isEmpty else {
                    throw invalid("unsupported foreign-process subtree")
                }
            }
            // Bound pending storage before appending, not after expanding a
            // device-provided children array into an unbounded traversal queue.
            guard children.count <= 512 - pending.count, depth < 32 || children.isEmpty else {
                throw invalid("snapshot exceeds 512 nodes or depth 32; no partial tree")
            }
            let index = nodes.count
            var node = Node(id: "n\(index)", parentId: parent.map { "n\($0)" }, depth: depth, token: token)
            node.label = try scalar(attributes["2001"])
            node.hint = try scalar(attributes["2002"])
            node.identifier = try scalar(attributes["5019"])
            node.value = try scalar(attributes["2006"])
            if let value = attributes["2003"], value != .null {
                if let frame = try rectangle(value) { node.frame = frame }
                else { node.frameUnavailable = "CGRectNull" }
            }
            if let value = attributes["2004"], value != .null {
                switch value {
                case .signed(let value): node.traits = String(UInt64(bitPattern: value))
                case .unsigned(let value): node.traits = String(value)
                default: throw invalid("traits must be an integer bit pattern")
                }
            }
            if let value = attributes["2025"], value != .null {
                if case .boolean(let visible) = value { node.visible = visible }
                else if let visible = value.unsignedInteger, visible <= 1 { node.visible = visible == 1 }
                else { throw invalid("visibility is not Boolean or integer 0/1") }
            }
            var metadata: [String: String] = [:]
            for key in ["5003", "5004", "3003"] {
                if let value = attributes[key], value != .null {
                    guard case .string(let text) = value else { throw invalid("class/bundle metadata is not a string") }
                    metadata[key] = text
                }
            }
            if !metadata.isEmpty { node.nativeAttributes = metadata }
            if token.pid != root.pid { node.processIdentifier = token.pid; node.externalProcessReference = true }
            if let parent { nodes[parent].children.append(node.id) }
            nodes.append(node)
            pending.append(contentsOf: children.map { ($0, index, depth + 1) })
        }
        return nodes
    }

    private static func scalar(_ value: AccessibilityArchiveValue?) throws -> Scalar? {
        guard let value, value != .null else { return nil }
        return try Scalar(value)
    }

    /// Parse only the native NSValue rectangle spelling; no runtime NSValue
    /// decoding or inferred rectangle from arbitrary arrays/dictionaries.
    static func rectangle(_ value: AccessibilityArchiveValue) throws -> Frame? {
        guard case .object("NSValue", let fields) = value, case .string(let text) = fields["NS.rectval"], text.utf8.count <= 1024 else {
            throw invalid("missing bounded native NSValue rectangle")
        }
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        func take(_ token: String) throws {
            guard scanner.scanString(token) != nil else { throw invalid("rectangle syntax") }
        }
        func number(upTo separator: String) throws -> Double {
            guard let text = scanner.scanUpToString(separator), let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw invalid("rectangle number")
            }
            return number
        }
        try take("{"); try take("{")
        let x = try number(upTo: ","); try take(",")
        let y = try number(upTo: "}"); try take("}"); try take(","); try take("{")
        let width = try number(upTo: ","); try take(",")
        let height = try number(upTo: "}"); try take("}"); try take("}")
        guard scanner.isAtEnd else { throw invalid("rectangle trailing data") }
        if x == .infinity, y == .infinity, width == 0, height == 0 { return nil }
        guard [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else { throw invalid("non-finite or negative-size rectangle") }
        return Frame(x: x, y: y, width: width, height: height)
    }

    private static func invalid(_ reason: String) -> CommandFailure {
        // A parser cannot know what its caller sent; callers refine inputSent.
        CommandFailure(.transportFailed, "Invalid native accessibility snapshot: \(reason).", inputSent: .unknown)
    }
}
