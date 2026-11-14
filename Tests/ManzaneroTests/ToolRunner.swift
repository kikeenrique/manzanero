import Foundation
import Testing
@testable import Manzanero

struct ToolRunnerTests {
    @Test func formatterSuccessCannotHideBuildFailure() throws {
        let log = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/build-log-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        do {
            try ToolRunner().build(["-c", "printf '** BUILD SUCCEEDED **\\n'; printf 'fixture stderr\\n' >&2; exit 7"], log: log, executable: "/bin/sh")
            Issue.record("A successful formatter must not turn exit 7 into build success")
        } catch {
            #expect(String(describing: error).contains("build failed (7)"))
        }
        let raw = try String(contentsOf: log, encoding: .utf8)
        #expect(raw.contains("BUILD SUCCEEDED"))
        #expect(raw.contains("fixture stderr"))
    }

    @Test func outputLargerThanPipeCapacity() throws {
        let output = try ToolRunner().run(["-c", "import sys; sys.stdout.write('x' * 200000)"], executable: "/usr/bin/python3")
        #expect(output.count == 200000)
    }

    @Test func nonzeroExitIncludesDiagnostic() {
        do {
            _ = try ToolRunner().run(["-c", "import sys; sys.stderr.write('expected failure'); sys.exit(7)"], executable: "/usr/bin/python3")
            Issue.record("Expected subprocess failure")
        } catch {
            #expect(String(describing: error).contains("expected failure"))
            #expect(String(describing: error).contains("(7)"))
        }
    }
}
