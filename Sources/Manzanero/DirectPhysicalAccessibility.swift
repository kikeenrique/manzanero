import Foundation

enum DirectPhysicalAccessibility {
    private static func applicationPID(_ input: CoreDeviceInput) throws -> Int32 {
        guard input.operation == "tree", input.operands.count == 1, let pid = Int32(input.operands[0]), pid > 0 else {
            throw CommandFailure.usage("Direct physical tree requires one positive application PID.")
        }
        return pid
    }

    /// Remain on the caller's actor while retaining non-Sendable native owners.
    /// Only local discovery subprocess work suspends; no owner crosses tasks.
    /// Attempts at the read-only connection setup before giving up.
    static let connectionAttempts = 3

    static func executeNativeRSD(_ input: CoreDeviceInput, isolation: isolated (any Actor)? = #isolation,
                                 query: (DeviceCommand) throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let action: DirectAccessibilityAction?
        let wait: AccessibilityWait?
        let pid: Int32?
        var setValue: DirectAccessibilitySetValue?
        if input.operation == "tree" {
            action = nil; wait = nil
            pid = input.operands.isEmpty ? nil : try applicationPID(input)
        } else if DirectAccessibilitySetValue.operations.contains(input.operation) {
            action = nil; wait = nil; pid = nil
            setValue = try DirectAccessibilitySetValue(input)
        } else if AccessibilityWait.operations.contains(input.operation) {
            action = nil; pid = nil
            wait = try AccessibilityWait(input)
        } else {
            action = try DirectAccessibilityAction(input)
            wait = nil; pid = nil
        }
        let details = try query(input.identityPlan())
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let result = root["result"] as? [String: Any], let properties = result["properties"] as? [String: Any],
              let hardware = properties["hardware"] as? [String: Any], let udid = hardware["udid"] as? String else {
            throw CommandFailure(.deviceNotReady, "Native physical AX requires fresh hardware identity; no connection started.", inputSent: .none)
        }
        let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid)
        let assertion = try NativeTunnelAssertion(device: udid, details: details)
        defer { assertion.close() }
        // Classifies a failure of an action: before it nothing was sent, it
        // classifies its own failures, and after it the input has been sent.
        var actionStage = 0
        do {
            // Port discovery, the RSD directory handshake and opening the AX
            // service occasionally fail on a healthy device ("Connection
            // invalid"). No accessibility request has been made at that point,
            // so the setup is repeated a bounded number of times.
            var connected: (directory: RSDDirectoryConnection, transport: any AccessibilitySessionTransport)?
            var attempt = 1
            while connected == nil {
                do {
                    let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
                    try Task.checkCancellation()
                    let candidate = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: udid)
                    do { connected = (candidate, try candidate.openAccessibility()) }
                    catch { candidate.close(); throw error }
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled, attempt < Self.connectionAttempts else { throw error }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            guard let (directory, transport) = connected else { throw CancellationError() }
            defer { directory.close() }
            let session = AccessibilitySession(transport: transport, limits: wait?.sessionLimits ?? .standard)
            let display = {
                    try Task.checkCancellation()
                    return try AccessibilityDisplay(query(AccessibilityDisplay.plan(device: identity.uuid)))
                }
            let bytes: Data
            if let action {
                actionStage = 1
                bytes = try action.execute(session: session, display: display)
                actionStage = 2
            }
            else if let setValue {
                actionStage = 1
                bytes = try setValue.execute(session: session, display: display)
                actionStage = 2
            }
            else if let wait {
                bytes = try await wait.execute(device: input.device, resolved: identity.uuid, session: session,
                                               display: display, clock: ContinuousClock())
            }
            else { bytes = try capture(device: input.device, resolved: identity.uuid, pid: pid, session: session, display: display) }
            directory.close()
            let release = assertion.close()
            if action != nil || setValue != nil, Task.isCancelled {
                FileHandle.standardError.write(Data("Native AX action completed, but cancellation withheld its receipt. Inspect before retrying. No automatic replay.\n".utf8))
            }
            try Task.checkCancellation()
            return try annotateNativeCleanup(bytes, release: release)
        } catch {
            let release = assertion.close()
            if Task.isCancelled || error is CancellationError {
                if !release.confirmed { FileHandle.standardError.write(Data("\(release.diagnostic ?? "Native tunnel release unconfirmed")\n".utf8)) }
                throw CancellationError()
            }
            let failure = CommandFailure("\(error) Tunnel assertion release: \(release.status); confirmed=\(release.confirmed). \(release.diagnostic ?? "")", wrapping: error)
            switch actionStage {
            case 0: throw failure.noInputSent()
            case 1: throw failure
            default: throw failure.inputPossiblySent()
            }
        }
    }

    static func annotateNativeCleanup(_ bytes: Data, release: NativeTunnelAssertion.Release) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommandFailure(.internal, "Invalid internal native AX result.", inputSent: .unknown)
        }
        root["transport"] = "apple-network-rsd"
        var cleanup: [String: Any] = ["tunnelAssertionRelease": release.status, "confirmed": release.confirmed]
        if let diagnostic = release.diagnostic { cleanup["diagnostic"] = diagnostic }
        root["connectionCleanup"] = cleanup
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func capture(device: String, resolved: String, pid: Int32?, session: any AccessibilityExchange,
                        display: () throws -> AccessibilityDisplay = {
                            throw CommandFailure(.internal, "Foreground AX requires an Apple display query.", inputSent: .none)
                        }, readFocus: Bool = false) throws -> Data {
        defer { session.close() }
        let platform = session.platform
        do {
            if let pid, pid <= 0 { throw CommandFailure.usage("Application PID must be positive.") }
            // Read Apple display geometry before subscribing, then bracket the
            // tree with centre-process and geometry rechecks. No action is sent.
            let selectedDisplay: AccessibilityDisplay?
            if pid == nil {
                selectedDisplay = try display()
            } else { selectedDisplay = nil }
            try session.start()
            let selectedPID: Int32
            if let pid { selectedPID = pid }
            else if let selectedDisplay {
                selectedPID = try session.foregroundProcess(selectedDisplay).pid
            } else { throw CommandFailure(.internal, "Missing AX selection.", inputSent: .none) }
            let root = try session.application(pid: selectedPID)
            let snapshot = try session.snapshot(root)
            var nodes = try AccessibilitySnapshot.normalize(snapshot, root: root)
            // An Apple TV is driven by focus, so its tree marks the focused node.
            if readFocus || selectedDisplay?.external == true, let focused = try focusedElement(of: root, session: session),
               let index = nodes.firstIndex(where: { $0.token.pid == focused.pid && $0.token.objectID == focused.objectID }) {
                nodes[index].focused = true
            }
            let after = try session.application(pid: selectedPID)
            guard root.pid == after.pid, root.objectID == after.objectID else {
                throw CommandFailure(.preconditionChanged, "Application identity changed during AX observation; no tree returned.", inputSent: .none)
            }
            if let selectedDisplay {
                let selectedAfter = try session.foregroundProcess(selectedDisplay)
                guard selectedAfter.pid == selectedPID else { throw CommandFailure(.preconditionChanged, "\(platform.capitalizedSelectionSubject) AX process changed during observation; no tree returned.", inputSent: .none) }
                guard try display() == selectedDisplay else { throw CommandFailure(.preconditionChanged, "Display geometry/orientation changed during observation; no tree returned.", inputSent: .none) }
            }
            try Task.checkCancellation()
            let cleanup = Cleanup(session.close())
            try Task.checkCancellation()
            return try JSONEncoder().encode(Observation(platform: platform, device: device, resolvedCoreDeviceUUID: resolved,
                application: Application(pid: selectedPID, selection: pid != nil ? "explicit-pid" : selectedDisplay?.external == true ? "frontmost" : platform.selection),
                display: selectedDisplay, nodes: nodes, cleanup: cleanup))
        } catch {
            let cleanup = Cleanup(session.close())
            if error is CancellationError { throw error }
            // A tree only reads, so nothing was sent whatever failed.
            throw CommandFailure("\(platform.failurePrefix) tree failed: \(error). Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed).", wrapping: error).noInputSent()
        }
    }

    /// The application's focused element (attribute 19), or nil when it
    /// answers with none. One read-only request.
    static func focusedElement(of root: AccessibilityRequest.Token, session: any AccessibilityExchange) throws -> AccessibilityRequest.Token? {
        let attribute = AccessibilityRequest.focusedElementAttribute
        guard case .dictionary(let fields) = try session.attributes([attribute], of: root) else {
            throw CommandFailure(.transportFailed, "The focused-element answer is not a dictionary.", inputSent: .none)
        }
        guard let value = fields[String(attribute)], value != .null else { return nil }
        return try AccessibilityResponse.token(value)
    }

    private struct Application: Encodable {
        let pid: Int32
        let selection: String
    }

    struct Cleanup: Encodable {
        let subscriptionStop: String
        let confirmed: Bool
        var diagnostic: String?
        init(_ outcome: AccessibilitySession.Cleanup) {
            switch outcome {
            case .notSubscribed: subscriptionStop = "not-subscribed"; confirmed = false
            case .stopAcknowledged: subscriptionStop = "acknowledged"; confirmed = true
            case .unconfirmed(let reason): subscriptionStop = "unconfirmed"; confirmed = false; diagnostic = reason
            case .notApplicable: subscriptionStop = "not-applicable"; confirmed = true
            }
        }
    }

    private struct Observation: Encodable {
        let platform: AccessibilityPlatform
        let format = "accessibility-tree"
        let schemaVersion = 1
        var backend: String { platform.backend }
        let parsedHierarchy = true
        let experimental = true
        let device: String
        let resolvedCoreDeviceUUID: String
        let application: Application
        let display: AccessibilityDisplay?
        var deviceAPIVersion: Int? { platform.deviceAPIVersion }
        let snapshotId = UUID().uuidString
        let nodes: [AccessibilitySnapshot.Node]
        let atomic = false
        let rootStabilityScope = "application-identity"
        let referenceScope = "snapshot-local-paths"
        let coordinateSpace = "device-logical-points"
        let cleanup: Cleanup
        var limitations: [String] { [
            display == nil ? "Explicit PID may identify a background app. Foreground/display selection is not checked." :
                platform.treeSelectionLimitation,
            "Root identity is checked twice; descendants can change. This is not an atomic snapshot or every UIView.",
            "Snapshot-local path IDs are not reusable action handles. Device caps and offscreen completeness are not independently verified.",
            platform.cleanupLimitation
        ] }
        var nodeCount: Int { nodes.count }

        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(format, forKey: Key("format"))
            try container.encode(schemaVersion, forKey: Key("schemaVersion"))
            try container.encode(backend, forKey: Key("backend"))
            try container.encode(parsedHierarchy, forKey: Key("parsedHierarchy"))
            try container.encode(experimental, forKey: Key("experimental"))
            try container.encode(device, forKey: Key("device"))
            try container.encode(resolvedCoreDeviceUUID, forKey: Key(platform.resolvedKey))
            try container.encode(application, forKey: Key("application"))
            try container.encodeIfPresent(display, forKey: Key("display"))
            try container.encodeIfPresent(deviceAPIVersion, forKey: Key("deviceAPIVersion"))
            try container.encode(snapshotId, forKey: Key("snapshotId"))
            try container.encode(nodes, forKey: Key("nodes"))
            try container.encode(nodeCount, forKey: Key("nodeCount"))
            try container.encode(atomic, forKey: Key("atomic"))
            try container.encode(rootStabilityScope, forKey: Key("rootStabilityScope"))
            try container.encode(referenceScope, forKey: Key("referenceScope"))
            try container.encode(coordinateSpace, forKey: Key("coordinateSpace"))
            try container.encode(cleanup, forKey: Key("cleanup"))
            try container.encode(limitations, forKey: Key("limitations"))
        }
    }
}
