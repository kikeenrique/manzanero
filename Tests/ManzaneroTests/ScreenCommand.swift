import Foundation
import CoreGraphics
import ImageIO
import MCP
import Testing
@testable import Manzanero

struct ScreenCommandTests {
    let device = "11111111-2222-3333-4444-555555555555"
    let tree = Data("[{\"role\":\"AXApplication\",\"children\":[{\"role\":\"AXStaticText\",\"AXLabel\":\"Synthetic label\"}]}]".utf8)

    func fixture(_ body: (URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/screen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    func png(_ url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    func json(_ data: Data) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func text(_ path: String) -> ScreenText {
        ScreenText(source: path, regions: [.init(text: "Synthetic", confidence: 0.9, x: 0.1, y: 0.2, width: 0.3, height: 0.1)])
    }

    @Test func validatesModesTargetsAndAcceptsForegroundPhysicalTree() throws {
        #expect(try ScreenCommand.parse(["simulator", device, "screen"])?.mode == .automatic)
        #expect(try ScreenCommand.parse(["physical", "fixture", "screen", "tree"])?.mode == .tree)
        for args in [["simulator", "booted", "screen"], ["simulator", device, "screen", "unknown"]] {
            #expect(throws: CommandFailure.self) { try ScreenCommand.parse(args) }
        }
        #expect(try ScreenCommand.parse(["simulator", device, "screen", "tree"])?.mode == .tree)
        #expect(try ScreenCommand.parse(["simulator", device, "screen", "ocr"])?.mode == .ocr)
    }

    @Test func simulatorAutoPrefersTheFrontmostApplicationTree() async throws {
        var hierarchy = try json(physicalTree())
        hierarchy["application"] = ["selection": "frontmost-application"]
        hierarchy["cleanup"] = ["subscriptionStop": "not-applicable", "confirmed": true]
        let data = try JSONSerialization.data(withJSONObject: hierarchy)
        try await fixture { directory in
            let screen = ScreenCommand(platform: "simulator", device: device, mode: .automatic)
            let result = try await screen.execute(directory: directory, run: { plan in
                #expect(plan.arguments.contains("screenshot"))
                try png(directory.appendingPathComponent("screen.png")); return Data()
            }, hierarchy: { data }, recognize: { _ in Issue.record("Useful simulator tree reached OCR"); return Self.text("unexpected") })
            let value = try json(result)
            #expect(value["method"] as? String == "accessibility")
            #expect(value["coordinateSpace"] as? String == "device-logical-points")
            #expect(value["diagnostics"] as? [String] == [])
        }
    }

    @Test func simulatorAutoFallsBackToOCRWhenTheTreeFails() async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: "simulator", device: device, mode: .automatic)
            let result = try await screen.execute(directory: directory, run: { plan in
                #expect(plan.arguments.contains("screenshot"))
                try png(directory.appendingPathComponent("screen.png")); return Data()
            }, hierarchy: { throw CommandFailure(.transportFailed, "Simulator tree failed: fixture.", inputSent: .none) }, recognize: { Self.text($0) })
            let value = try json(result)
            #expect(value["method"] as? String == "ocr")
            #expect(value["coordinateSpace"] as? String == "normalized-top-left")
            #expect((value["image"] as? [String: Any])?["width"] as? Int == 40)
            #expect(value["diagnostics"] as? [String] == ["Accessibility unavailable: Simulator tree failed: fixture."])
        }
    }

    @Test(arguments: [Data("[]".utf8), Data("{".utf8), Data("{\"role\":\"AXApplication\",\"AXLabel\":\"Only app name\"}".utf8)])
    func autoFallsBackFromEmptyMalformedOrWrapperOnlyTree(_ hierarchy: Data) async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: "physical", device: "fixture", mode: .automatic)
            let result = try await screen.execute(directory: directory, run: { plan in
                #expect(plan.arguments.contains("screenshot"))
                try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
            }, hierarchy: { hierarchy }, recognize: { Self.text($0) })
            let value = try json(result)
            #expect(value["method"] as? String == "ocr")
            #expect(value["coordinateSpace"] as? String == "normalized-top-left")
            #expect((value["textRegions"] as? [[String: Any]])?.first?["text"] as? String == "Synthetic")
            #expect((value["diagnostics"] as? [String])?.isEmpty == false)
        }
    }

    @Test(arguments: ["physical", "simulator"]) func autoReturnsImageOnlyWhenBothAnalysisBackendsFail(platform: String) async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: platform, device: device, mode: .automatic)
            let result = try await screen.execute(directory: directory, run: { plan in
                #expect(plan.arguments.contains("screenshot"))
                try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
            }, hierarchy: { throw CommandFailure(description: "fixture AX unavailable") },
               recognize: { _ in throw CommandFailure(description: "fixture OCR unavailable") })
            let value = try json(result)
            #expect(value["method"] as? String == "image-only")
            #expect(value["status"] as? String == "partial")
            #expect((value["diagnostics"] as? [String])?.count == 2)
            #expect(value["hierarchy"] == nil && value["textRegions"] == nil)
        }
    }

    @Test func forcedOCRSkipsHierarchyAndDoesNotMaskRecognitionFailure() async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: "simulator", device: device, mode: .ocr)
            await #expect(throws: CommandFailure.self) {
                try await screen.execute(directory: directory, run: { plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try png(directory.appendingPathComponent("screen.png")); return Data()
                }, hierarchy: { Issue.record("Forced OCR requested a hierarchy"); return tree },
                   recognize: { _ in throw CommandFailure(description: "fixture OCR unavailable") })
            }
        }
    }

    @Test func invalidCaptureStopsBeforeAnalysis() async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: "simulator", device: device, mode: .automatic)
            await #expect(throws: CommandFailure.self) {
                try await screen.execute(directory: directory, run: { plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try Data("not a PNG".utf8).write(to: directory.appendingPathComponent("screen.png")); return Data()
                }, hierarchy: { Issue.record("Invalid capture reached hierarchy"); return tree }, recognize: { _ in Issue.record("Invalid capture reached OCR"); return Self.text("invalid") })
            }
        }
    }

    @Test(arguments: ["physical", "simulator"]) func cancellationIsNotConvertedIntoImageOnlySuccess(platform: String) async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform: platform, device: device, mode: .automatic)
            await #expect(throws: CancellationError.self) {
                try await screen.execute(directory: directory, run: { plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
                }, hierarchy: { throw CommandFailure(description: "fixture AX unavailable") },
                   recognize: { _ in throw CancellationError() })
            }
        }
    }

    @Test func mcpImageContentUsesGeneratedResultPath() async throws {
        try await fixture { directory in
            let image = directory.appendingPathComponent("screen.png")
            try png(image)
            let output = try JSONSerialization.data(withJSONObject: ["method": "image-only", "status": "partial", "imagePath": image.path])
            let result = try await MCPTools.call(name: "get_screen", arguments: ["platform": "simulator", "device": .string(device)]) { _ in CommandOutput(data: output) }
            #expect(result.isError == false)
            let content = try #require(result.content.first { if case .image = $0 { return true }; return false })
            if case .image(let base64, let mime, _, _) = content {
                #expect(mime == "image/png")
                #expect(Data(base64Encoded: base64) == (try Data(contentsOf: image)))
            }
        }
    }

    func physicalTree() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format":"accessibility-tree", "parsedHierarchy":true,
            "application":["selection":"centre-hit-test"],"coordinateSpace":"device-logical-points","nodeCount":2,
            "nodes":[["id":"n0","label":"App"],["id":"n1","label":"Button","visible":true]]])
    }

    @Test func nativeHierarchyProviderAvoidsHelperAndPreservesSeparateCleanupDiagnostics() async throws {
        var tree = try json(physicalTree())
        tree["cleanup"] = ["confirmed": false, "diagnostic": "AX stop lost"]
        tree["connectionCleanup"] = ["confirmed": false, "diagnostic": "Assertion release lost"]
        let data = try JSONSerialization.data(withJSONObject: tree)
        try await fixture { directory in
            var captures = 0
            var reads = 0
            let result = try await ScreenCommand(platform: "physical", device: "fixture", mode: .tree)
                .execute(directory: directory, run: { plan in
                    #expect(plan.arguments.contains("screenshot"))
                    captures += 1
                    try png(directory.appendingPathComponent("screen.png"))
                    return Data("{}".utf8)
                }, hierarchy: {
                    #expect(captures == 1)
                    reads += 1
                    return data
                }, recognize: { _ in Issue.record("Native hierarchy reached OCR"); throw CancellationError() })
            let object = try json(result)
            #expect(captures == 1 && reads == 1)
            #expect(object["method"] as? String == "accessibility")
            #expect(object["diagnostics"] as? [String] == ["cleanup unconfirmed: AX stop lost", "connectionCleanup unconfirmed: Assertion release lost"])
        }
    }

    @Test(arguments: [false, true]) func physicalAutoPrefersForegroundTreeAndPreservesItsCoordinateSpace(cleanupWarning: Bool) async throws {
        var hierarchy = try json(physicalTree())
        if cleanupWarning { hierarchy["cleanup"] = ["subscriptionStop":"connection-closed-before-ack", "warning":"Cleanup unconfirmed."] }
        let data = try JSONSerialization.data(withJSONObject: hierarchy)
        try await fixture { directory in
            let screen = ScreenCommand(platform:"physical",device:"fixture",mode:.automatic)
            let result = try await screen.execute(directory:directory,run:{ plan in
                #expect(plan.arguments.contains("screenshot"))
                try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
            },hierarchy:{ data },recognize:{ _ in Issue.record("Useful physical tree reached OCR"); throw CommandFailure(description:"unexpected OCR") })
            #expect(try json(result)["method"] as? String == "accessibility")
            #expect(try json(result)["coordinateSpace"] as? String == "device-logical-points")
            #expect(try json(result)["diagnostics"] as? [String] == (cleanupWarning ? ["Cleanup unconfirmed."] : []))
        }
    }

    @Test func physicalFallbackRejectsBackgroundAndInconsistentTreeMetadata() async throws {
        for invalid in ["background","count","hidden"] {
            var value = try json(physicalTree())
            if invalid == "background" { value["application"] = ["selection":"explicit-pid"] }
            if invalid == "count" { value["nodeCount"] = 3 }
            if invalid == "hidden" { value["nodes"] = [["id":"n0","label":"App"],["id":"n1","label":"Button","visible":false]] }
            let data = try JSONSerialization.data(withJSONObject:value)
            try await fixture { directory in
                let screen = ScreenCommand(platform:"physical",device:"fixture",mode:.automatic)
                let result = try await screen.execute(directory:directory,run:{ plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
                },hierarchy:{ data },recognize:{ Self.text($0) })
                #expect(try json(result)["method"] as? String == "ocr")
            }
        }
    }

    @Test func forcedPhysicalTreeFailureKeepsScreenshotAndDoesNotUseOCR() async throws {
        try await fixture { directory in
            let screen = ScreenCommand(platform:"physical",device:"fixture",mode:.tree)
            do {
                _ = try await screen.execute(directory:directory,run:{ plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try png(directory.appendingPathComponent("screen.png")); return Data("{}".utf8)
                },hierarchy:{ throw CommandFailure(description:"fixture AX unavailable") },recognize:{ _ in Issue.record("Forced tree reached OCR"); return Self.text("unexpected") })
                Issue.record("Forced tree failure was hidden")
            } catch {
                #expect(String(describing:error).contains("Screenshot saved at"))
                #expect(FileManager.default.fileExists(atPath:directory.appendingPathComponent("screen.png").path))
            }
        }
    }
}
