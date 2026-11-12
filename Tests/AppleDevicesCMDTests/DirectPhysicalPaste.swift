import AppleDeviceBridge
import Foundation
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalPasteTests {
    private func input(_ text: String = "mañana 🚀 中") -> CoreDeviceInput {
        CoreDeviceInput(device: CoreDeviceInputTests().udid, operation: "paste", operands: [text])
    }

    @Test func writesLiteralUTF8BeforeOneBalancedPasteChord() throws {
        let text = "mañana 🚀 中\n'\"$`\\\t"
        var phases: [String] = []
        let output = try DirectPhysicalPaste.execute(input(text), query: { _ in
            phases.append("identity")
            return try DirectPhysicalInputTests().details()
        }, copy: { plan, bytes in
            #expect(phases == ["identity"])
            phases.append("copy")
            #expect(plan.executable == "/usr/bin/xcrun")
            #expect(plan.arguments == ["devicectl", "device", "pasteboard", "copy", "--device", CoreDeviceInputTests().uuid,
                "--timeout", "30", "--quiet", "--json-output", "-"])
            #expect(plan.arguments.contains(text) == false)
            #expect(bytes == Data(text.utf8))
            return Data(#"{"info":{"outcome":"success"}}"#.utf8)
        }, send: { dispatch in
            #expect(phases == ["identity", "copy"])
            phases.append("send")
            #expect(dispatch.uuid == CoreDeviceInputTests().uuid && dispatch.version == "651.32")
            #expect(dispatch.samples.map(\.usage) == [227, 25, 25, 227])
            #expect(dispatch.samples.map(\.state) == [1, 1, 2, 2])
            #expect(dispatch.samples.map(\.nanoseconds) == [0, 40_000_000, 120_000_000, 160_000_000])
        })
        #expect(phases == ["identity", "copy", "send"])
        let receipt = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(receipt["backend"] as? String == "coredevice-direct")
        #expect(receipt["clipboard"] as? String == "replaced")
        #expect(receipt["insertionVerified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
        #expect(String(decoding: output, as: UTF8.self).contains(text) == false)
    }

    @Test(arguments: [0, 1, 65537])
    func invalidTextHasNoDeviceEffects(_ size: Int) {
        let text = size == 1 ? "nul\0text" : String(repeating: "x", count: size)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalPaste.execute(input(text), query: { _ in Issue.record("Invalid text queried"); return Data() },
                copy: { _, _ in Issue.record("Invalid text copied"); return Data() }, send: { _ in Issue.record("Invalid text sent") })
        }
    }

    @Test func readinessFailurePreventsClipboardWrite() throws {
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalPaste.execute(input(), query: { _ in try DirectPhysicalInputTests().details(mode: "disabled") },
                copy: { _, _ in Issue.record("Disabled device copied clipboard"); return Data() }, send: { _ in Issue.record("Disabled device sent keys") })
        }
    }

    @Test func copyFailureNeverPastesAndDispatchFailureNeverReplays() throws {
        for response in [Data(), Data(#"{"info":{"outcome":"failure"}}"#.utf8)] {
            do {
                _ = try DirectPhysicalPaste.execute(input(), query: { _ in try DirectPhysicalInputTests().details() },
                    copy: { _, _ in response }, send: { _ in Issue.record("Unconfirmed clipboard pasted") })
                Issue.record("Expected copy error")
            } catch { #expect(String(describing: error).contains("clipboard state may have changed")) }
        }
        var copies = 0, sends = 0
        do {
            _ = try DirectPhysicalPaste.execute(input(), query: { _ in try DirectPhysicalInputTests().details() }, copy: { _, _ in
                copies += 1; return Data(#"{"info":{"outcome":"success"}}"#.utf8)
            }, send: { _ in sends += 1; throw CommandFailure(description: "fixture failure") })
            Issue.record("Expected dispatch error")
        } catch { #expect(String(describing: error).contains("Clipboard was replaced")) }
        #expect(copies == 1 && sends == 1)
    }

    @Test func cRejectsMalformedSchedulesBeforeLoadingFramework() {
        let valid = DirectPhysicalPaste.samples
        let invalid: [[ADCKeyboardSample]] = [[], Array(valid.dropLast()),
            [.init(nanoseconds: 0, usage: .max, state: 1), .init(nanoseconds: 1, usage: .max, state: 2)],
            [.init(nanoseconds: 0, usage: 25, state: 2), .init(nanoseconds: 1, usage: 25, state: 1)],
            [.init(nanoseconds: 0, usage: 25, state: 1), .init(nanoseconds: 1, usage: 25, state: 1)],
            [.init(nanoseconds: 0, usage: 25, state: 1), .init(nanoseconds: 0, usage: 25, state: 2)],
            [.init(nanoseconds: 1, usage: 25, state: 1), .init(nanoseconds: 2, usage: 25, state: 2)],
            [.init(nanoseconds: 0, usage: 25, state: 1), .init(nanoseconds: 32_000_000_000, usage: 25, state: 2)]]
        for sequence in invalid {
            var error = [CChar](repeating: 0, count: 1024)
            let result = sequence.withUnsafeBufferPointer { ADCPerformKeyboard("invalid", "invalid", $0.baseAddress, $0.count, &error, error.count) }
            #expect(result != 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased().contains("keyboard"))
        }
    }

    @Test func defaultAndExplicitDryRunExposeClipboardEffectWithoutQueries() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried"); return Data() })
        for prefix in [[], ["--physical-backend", "coredevice"]] {
            let output = try await service.execute(prefix + ["physical", CoreDeviceInputTests().udid, "paste", "🚀"], dryRun: true)
            let result = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(result["backend"] as? String == "coredevice-direct")
            #expect(result["stdinUTF8Bytes"] as? Int == 4)
            #expect(result["clipboardEffect"] as? String != nil)
            #expect(result["actionArguments"] == nil)
        }
    }
}
