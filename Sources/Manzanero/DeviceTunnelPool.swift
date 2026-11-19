import Foundation

/// The process's one tunnel of the tool's own, kept between commands.
///
/// A process has one `DeviceTunnel` at a time. An MCP server or a `batch`
/// runs many accessibility commands, and opening a tunnel for each costs a
/// device session and a greeting every time, so the pool hands the same
/// tunnel to each command for the same device and closes it after it has
/// stood idle. A command for another device while the tunnel is in use gets
/// a refusal and keeps the route over Apple's tunnel.
final class DeviceTunnelPool: @unchecked Sendable {
    static let shared = DeviceTunnelPool()

    /// A tunnel nobody has used for this long is closed.
    static let idleSeconds: TimeInterval = 30

    private let lock = NSLock()
    private var device: String?
    private var tunnel: DeviceTunnel?
    private var users = 0
    private var lastUse = Date.distantPast
    private let open: @Sendable (String) throws -> DeviceTunnel
    private let enabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    init(open: @escaping @Sendable (String) throws -> DeviceTunnel = { try DeviceTunnel(device: $0) },
         enabled: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.environment[DeviceTunnel.optIn] == "1" },
         now: @escaping @Sendable () -> Date = Date.init) {
        self.open = open
        self.enabled = enabled
        self.now = now
    }

    /// The tunnel for the device, opened if need be. Nil when the tool's own
    /// tunnel was not asked for; a failure says why it cannot be used, and
    /// the caller keeps the route it had.
    func acquire(_ udid: String) -> Result<DeviceTunnel, CommandFailure>? {
        guard enabled() else { return nil }
        return lock.withLock {
            if let tunnel, device == udid, tunnel.isAlive {
                users += 1
                return .success(tunnel)
            }
            if let tunnel {
                guard users == 0 else {
                    return .failure(CommandFailure(.deviceBusy, "The tool's own tunnel is in use for another device in this process.", inputSent: .none))
                }
                tunnel.close()
                self.tunnel = nil
                device = nil
            }
            do {
                let opened = try open(udid)
                tunnel = opened
                device = udid
                users = 1
                return .success(opened)
            } catch let failure as CommandFailure {
                return .failure(failure)
            } catch {
                return .failure(CommandFailure(.transportFailed, "\(error)", inputSent: .none))
            }
        }
    }

    /// Gives the tunnel back. An unhealthy one (a transport failure during
    /// the command) is closed as soon as nobody else uses it.
    func release(_ released: DeviceTunnel, healthy: Bool) {
        let idle = lock.withLock { () -> Bool in
            guard let tunnel, tunnel === released else {
                released.close()
                return false
            }
            users = max(0, users - 1)
            lastUse = now()
            guard users == 0 else { return false }
            if !healthy || !tunnel.isAlive {
                tunnel.close()
                self.tunnel = nil
                device = nil
                return false
            }
            return true
        }
        guard idle else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleSeconds + 0.5) { [weak self] in self?.closeIfIdle() }
    }

    /// Closes the tunnel when nobody uses it and it has stood idle.
    func closeIfIdle() {
        lock.withLock {
            guard let tunnel, users == 0, now().timeIntervalSince(lastUse) >= Self.idleSeconds else { return }
            tunnel.close()
            self.tunnel = nil
            device = nil
        }
    }
}

/// Where an accessibility command gets the tool's own tunnel and gives it back.
struct OwnTunnelSource: Sendable {
    var acquire: @Sendable (_ udid: String) -> Result<DeviceTunnel, CommandFailure>?
    var release: @Sendable (_ tunnel: DeviceTunnel, _ healthy: Bool) -> Void

    static let pooled = OwnTunnelSource(acquire: { DeviceTunnelPool.shared.acquire($0) },
                                        release: { DeviceTunnelPool.shared.release($0, healthy: $1) })
    /// Never offers a tunnel.
    static let none = OwnTunnelSource(acquire: { _ in nil }, release: { _, _ in })
}
