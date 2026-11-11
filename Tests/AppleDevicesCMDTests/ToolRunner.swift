import Foundation
import Testing
@testable import AppleDevicesCMD

struct ToolRunnerTests {
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
