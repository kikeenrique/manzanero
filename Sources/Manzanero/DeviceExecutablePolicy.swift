import Foundation

/// Device operations may use Apple executables, never third-party device drivers.
/// Build-output formatters and process test fixtures are not device backends.
enum DeviceExecutablePolicy {
    static func validate(_ executable: String, arguments: [String]) throws {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let command = name == "env"
            ? arguments.first(where: { !$0.contains("=") && !$0.hasPrefix("-") }).map { URL(fileURLWithPath: $0).lastPathComponent }
            : name
        guard let command else { return }
        let isAppleSystemExecutable = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/"].contains {
            executable.hasPrefix($0) && !executable.dropFirst($0.count).contains("/")
        }
        // xcsift formats host build logs; it is never a device controller.
        if executable == "/usr/bin/env", arguments.first == "xcsift" { return }
        // Apple's remote-service client is outside the ordinary system bin dirs.
        if executable == "/usr/libexec/remotectl" { return }
        // Apple's firewall tool, used only to read whether incoming video is allowed.
        if executable == HostFirewall.tool { return }
        guard name != "env", isAppleSystemExecutable else {
            throw CommandFailure(description: "The \(command) executable backend is disabled: device operations must call Apple frameworks/APIs directly or use Apple executables. Its in-process replacement is not yet available for this operation.")
        }
    }
}
