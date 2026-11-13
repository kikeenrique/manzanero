import AppleDeviceBridge
import Foundation

enum DirectPhysicalAccessibility {
    private static func applicationPID(_ input: CoreDeviceInput) throws -> Int32 {
        guard input.operation == "tree", input.operands.count == 1, let pid = Int32(input.operands[0]), pid > 0 else {
            throw CommandFailure(description: "Direct physical tree requires one positive application PID.")
        }
        return pid
    }

    /// Remain on the caller's actor while retaining non-Sendable native owners.
    /// Only local discovery subprocess work suspends; no owner crosses tasks.
    static func executeNativeRSD(_ input: CoreDeviceInput, isolation: isolated (any Actor)? = #isolation,
                                 query: (DeviceCommand) throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let pid = try applicationPID(input)
        let details = try query(input.identityPlan())
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let result = root["result"] as? [String: Any], let properties = result["properties"] as? [String: Any],
              let hardware = properties["hardware"] as? [String: Any], let udid = hardware["udid"] as? String else {
            throw CommandFailure(description: "Native physical tree requires fresh hardware identity; no connection started.")
        }
        let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid)
        let assertion = try NativeTunnelAssertion(device: udid, details: details)
        defer { assertion.close() }
        do {
            let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
            try Task.checkCancellation()
            let directory = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: udid, transport: .network)
            defer { directory.close() }
            let transport = try directory.openAccessibility()
            let bytes = try capture(device: input.device, resolved: identity.uuid, pid: pid, session: AccessibilitySession(transport: transport))
            directory.close()
            let release = assertion.close()
            try Task.checkCancellation()
            return try annotateNativeCleanup(bytes, release: release)
        } catch {
            let release = assertion.close()
            if Task.isCancelled || error is CancellationError {
                if !release.confirmed { FileHandle.standardError.write(Data("\(release.diagnostic ?? "Native tunnel release unconfirmed")\n".utf8)) }
                throw CancellationError()
            }
            throw CommandFailure(description: "\(error) Tunnel assertion release: \(release.status); confirmed=\(release.confirmed). \(release.diagnostic ?? "")")
        }
    }

    static func annotateNativeCleanup(_ bytes: Data, release: NativeTunnelAssertion.Release) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommandFailure(description: "Invalid internal native tree result.")
        }
        root["transport"] = "apple-network-rsd"
        var cleanup: [String: Any] = ["tunnelAssertionRelease": release.status, "confirmed": release.confirmed]
        if let diagnostic = release.diagnostic { cleanup["diagnostic"] = diagnostic }
        root["connectionCleanup"] = cleanup
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        open: (String, String) throws -> any AccessibilitySessionTransport = openSocket) throws -> Data {
        let pid = try applicationPID(input)
        let identity = try DirectPhysicalInput.identity(input, query: query)
        try Task.checkCancellation()
        let transport = try open(identity.uuid, identity.version)
        let session = AccessibilitySession(transport: transport)
        return try capture(device: input.device, resolved: identity.uuid, pid: pid, session: session)
    }

    static func capture(device: String, resolved: String, pid: Int32, session: AccessibilitySession) throws -> Data {
        defer { session.close() }
        do {
            guard pid > 0 else { throw CommandFailure(description: "Application PID must be positive.") }
            try session.start()
            let root = try session.application(pid: pid)
            let snapshot = try session.snapshot(root)
            let nodes = try AccessibilitySnapshot.normalize(snapshot, root: root)
            let after = try session.application(pid: pid)
            guard root.pid == after.pid, root.objectID == after.objectID else {
                throw CommandFailure(description: "Application identity changed during AX observation; no tree returned.")
            }
            try Task.checkCancellation()
            let cleanup = Cleanup(session.close())
            try Task.checkCancellation()
            return try JSONEncoder().encode(Observation(device: device, resolvedCoreDeviceUUID: resolved,
                application: Application(pid: pid), nodes: nodes, cleanup: cleanup))
        } catch {
            let cleanup = Cleanup(session.close())
            if error is CancellationError { throw error }
            throw CommandFailure(description: "Direct physical tree failed: \(error). Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed).")
        }
    }

    private struct Application: Encodable {
        let pid: Int32
        let selection = "explicit-pid"
    }

    private struct Cleanup: Encodable {
        let subscriptionStop: String
        let confirmed: Bool
        var diagnostic: String?
        init(_ outcome: AccessibilitySession.Cleanup) {
            switch outcome {
            case .notSubscribed: subscriptionStop = "not-subscribed"; confirmed = false
            case .stopAcknowledged: subscriptionStop = "acknowledged"; confirmed = true
            case .unconfirmed(let reason): subscriptionStop = "unconfirmed"; confirmed = false; diagnostic = reason
            }
        }
    }

    private struct Observation: Encodable {
        let format = "accessibility-tree"
        let schemaVersion = 1
        let backend = "coredevice-direct"
        let parsedHierarchy = true
        let experimental = true
        let device: String
        let resolvedCoreDeviceUUID: String
        let application: Application
        let deviceAPIVersion = 26
        let snapshotId = UUID().uuidString
        let nodes: [AccessibilitySnapshot.Node]
        let atomic = false
        let rootStabilityScope = "application-identity"
        let referenceScope = "snapshot-local-paths"
        let coordinateSpace = "device-logical-points"
        let cleanup: Cleanup
        let limitations = [
            "Explicit PID may identify a background app. Foreground/display selection is not checked.",
            "Root identity is checked twice; descendants can change. This is not an atomic snapshot or every UIView.",
            "Snapshot-local path IDs are not reusable action handles. Device caps and offscreen completeness are not independently verified.",
            "A disable acknowledgement is not independent verification of phone-side subscription teardown."
        ]
        var nodeCount: Int { nodes.count }

        enum CodingKeys: String, CodingKey {
            case format, schemaVersion, backend, parsedHierarchy, experimental, device, resolvedCoreDeviceUUID
            case application, deviceAPIVersion, snapshotId, nodes, atomic, rootStabilityScope, referenceScope, coordinateSpace, cleanup, limitations, nodeCount
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(format, forKey: .format)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(backend, forKey: .backend)
            try container.encode(parsedHierarchy, forKey: .parsedHierarchy)
            try container.encode(experimental, forKey: .experimental)
            try container.encode(device, forKey: .device)
            try container.encode(resolvedCoreDeviceUUID, forKey: .resolvedCoreDeviceUUID)
            try container.encode(application, forKey: .application)
            try container.encode(deviceAPIVersion, forKey: .deviceAPIVersion)
            try container.encode(snapshotId, forKey: .snapshotId)
            try container.encode(nodes, forKey: .nodes)
            try container.encode(nodeCount, forKey: .nodeCount)
            try container.encode(atomic, forKey: .atomic)
            try container.encode(rootStabilityScope, forKey: .rootStabilityScope)
            try container.encode(referenceScope, forKey: .referenceScope)
            try container.encode(coordinateSpace, forKey: .coordinateSpace)
            try container.encode(cleanup, forKey: .cleanup)
            try container.encode(limitations, forKey: .limitations)
        }
    }

    private static func openSocket(uuid: String, version: String) throws -> any AccessibilitySessionTransport {
        var owner: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 1024)
        let descriptor = ADCOpenAccessibilitySocket(uuid, version, &owner, &error, error.count)
        guard descriptor >= 0 else {
            throw CommandFailure(description: "Direct physical AX endpoint unavailable: " + String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return try AccessibilitySocketTransport(taking: descriptor, owner: owner)
    }
}
