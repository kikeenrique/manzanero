import Foundation
import Testing
@testable import Manzanero

struct HostFirewallTests {
    private static let executable = "/opt/example/libexec/manzanero"
    private static let apps = """
        Total number of apps = 3\u{20}
        1 : /opt/example/old/manzanero\u{20}
                     (Allow incoming connections)\u{20}
        2 : /opt/example/libexec/manzanero\u{20}
                     (Block incoming connections)\u{20}
        3 : /Applications/Example.app\u{20}
                     (Allow incoming connections)\u{20}
        """

    private func check(state: String?, apps: String? = HostFirewallTests.apps, executable: String = HostFirewallTests.executable) -> HostFirewall {
        HostFirewall.check(executable: executable, run: { arguments in
            let output = arguments == ["--getglobalstate"] ? state : apps
            guard let output else { throw CommandFailure(description: "fixture tool failure") }
            return Data(output.utf8)
        })
    }

    @Test func disabledFirewallNeedsNoRule() {
        let firewall = check(state: "Firewall is disabled. (State = 0)")
        #expect(firewall.status == .off && !firewall.dropsIncoming && firewall.action == nil && firewall.recordingHint == nil)
    }

    @Test(arguments: ["Firewall is enabled. (State = 1)", "Firewall is enabled. (State = 2)"])
    func rulesAreMatchedByExactPath(state: String) {
        #expect(check(state: state).status == .blocked)
        #expect(check(state: state, executable: "/opt/example/old/manzanero").status == .allowed)
        #expect(check(state: state, executable: "/Applications/Example.app").status == .allowed)
        // A prefix or a different location is a different executable.
        #expect(check(state: state, executable: "/opt/example/libexec/manzanero-next").status == .noRule)
        #expect(check(state: state, executable: "/opt/example/libexec").status == .noRule)
    }

    @Test func missingRuleExplainsTheSymptomAndTheRemedy() throws {
        let firewall = check(state: "Firewall is enabled. (State = 1)", apps: "Total number of apps = 0")
        #expect(firewall.status == .noRule && firewall.dropsIncoming)
        let hint = try #require(firewall.recordingHint)
        #expect(hint.contains("no rule for this executable") && hint.contains(Self.executable))
        #expect(hint.contains("System Settings > Network > Firewall"))
        let entry = firewall.doctorEntry
        #expect(entry["kind"] as? String == "host-network" && entry["status"] as? String == "no-rule")
        #expect(entry["affects"] as? [String] == ["native-recording"])
        #expect((entry["action"] as? String)?.contains("--unblockapp") == true)
    }

    @Test func unreadableStateIsUnknownAndClaimsNothing() {
        for firewall in [check(state: nil), check(state: "unexpected output"), check(state: "Firewall is enabled. (State = 1)", apps: nil)] {
            #expect(firewall.status == .unknown && !firewall.dropsIncoming && firewall.recordingHint == nil)
        }
    }

    @Test func doctorListsTheFirewallWithoutChangingItsExitCode() throws {
        let host = DoctorHost.current(xcodeOutput: nil)
        let blocked = HostFirewall(status: .blocked, executable: Self.executable)
        let output = try Doctor.report(tools: [.init(name: "Xcode")], host: host, capabilities: [], firewall: blocked)
        #expect(output.exitCode == 0)
        let entries = try #require(JSONSerialization.jsonObject(with: output.data) as? [[String: Any]])
        let entry = try #require(entries.first { $0["name"] as? String == "Firewall" })
        #expect(entry["status"] as? String == "blocked" && entry["executable"] as? String == Self.executable)
        let without = try Doctor.report(tools: [.init(name: "Xcode")], host: host, capabilities: [])
        let plain = try #require(JSONSerialization.jsonObject(with: without.data) as? [[String: Any]])
        #expect(!plain.contains { $0["name"] as? String == "Firewall" })
    }

    @Test func policyAllowsOnlyApplesFirewallToolAtItsExactPath() throws {
        try DeviceExecutablePolicy.validate(HostFirewall.tool, arguments: ["--getglobalstate"])
        #expect(throws: CommandFailure.self) {
            try DeviceExecutablePolicy.validate("/usr/libexec/ApplicationFirewall/other", arguments: [])
        }
        #expect(throws: CommandFailure.self) {
            try DeviceExecutablePolicy.validate("/opt/example/socketfilterfw", arguments: ["--getglobalstate"])
        }
    }

    @Test func realHostCheckReturnsAWellFormedResult() {
        let firewall = HostFirewall.check()
        #expect(!firewall.executable.isEmpty)
        #expect(firewall.doctorEntry["status"] as? String == firewall.status.rawValue)
    }
}
