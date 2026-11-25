import Foundation
import Testing

/// doctor's interface table (AppleInterfaceAvailability.m) is what the
/// hardened-runtime check loads (`mise run check:hardened`): a framework the
/// bridge opens and the table does not list would be untested there.
struct InterfaceTableCoverageTests {
    static let bridge = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/AppleDeviceBridge").standardized

    /// Every `dlopen` in the bridge: its path (a literal, or an `NSString`
    /// constant of the same file) and its flags, with spacing removed.
    static func opened() throws -> [(file: String, path: String, flags: String)] {
        let files = try FileManager.default.contentsOfDirectory(atPath: bridge.path).filter { $0.hasSuffix(".m") }
        let call = try Regex(#"dlopen\(\s*("([^"]+)"|([A-Za-z_][A-Za-z0-9_]*)\.fileSystemRepresentation)\s*,\s*([^)]+)\)"#)
        let constant = try Regex(#"NSString\s*\*\s*const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*@"([^"]+)""#)
        var found: [(String, String, String)] = []
        for file in files where file != "AppleInterfaceAvailability.m" {
            let source = try String(contentsOf: bridge.appendingPathComponent(file), encoding: .utf8)
            var constants: [String: String] = [:]
            for match in source.matches(of: constant) {
                if let name = match.output[1].substring, let value = match.output[2].substring { constants[String(name)] = String(value) }
            }
            for match in source.matches(of: call) {
                let literal = match.output[2].substring.map(String.init)
                let named = match.output[3].substring.flatMap { constants[String($0)] }
                guard let path = literal ?? named, let flags = match.output[4].substring else {
                    Issue.record("\(file): a dlopen whose path this test cannot read: \(match.output[0].substring ?? "")")
                    continue
                }
                found.append((file, path, flags.filter { !$0.isWhitespace }))
            }
        }
        return found
    }

    @Test func everyFrameworkTheBridgeOpensIsInDoctorsTable() throws {
        let table = try String(contentsOf: Self.bridge.appendingPathComponent("AppleInterfaceAvailability.m"), encoding: .utf8)
        let entry = try Regex(#"ADC_FRAMEWORK\("([^"]+)",\s*([^)]+)\)"#)
        let listed = Set(table.matches(of: entry).compactMap { match -> String? in
            guard let path = match.output[1].substring, let flags = match.output[2].substring else { return nil }
            return "\(path) \(flags.filter { !$0.isWhitespace })"
        })
        let opened = try Self.opened()
        #expect(opened.count >= 6, "expected the bridge's dlopen calls; found \(opened.count)")
        for (file, path, flags) in opened {
            #expect(listed.contains("\(path) \(flags)"),
                    "\(file) opens \(path) with \(flags), which doctor's table does not list with those flags; add an ADC_FRAMEWORK entry to the capability that uses it")
        }
    }
}
