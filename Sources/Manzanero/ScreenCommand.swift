import Foundation
import ImageIO

struct ScreenCommand: Sendable, Equatable {
    enum Mode: String, Sendable { case automatic = "auto", tree, ocr }
    let platform: String
    let device: String
    let mode: Mode

    func capturePlan(image: URL) throws -> DeviceCommand {
        try DeviceCommand.plan(physical: platform == "physical", device: device, operation: "screenshot", operands: [image.path])
    }

    /// `hierarchy` reads the AX tree: the display-centre app on a physical
    /// device, the frontmost application on a simulator.
    func execute(directory: URL, run: (DeviceCommand) throws -> Data,
                 hierarchy: () async throws -> Data,
                 recognize: @Sendable (String) async throws -> ScreenText = { try await ScreenText.recognize(path: $0) },
                 isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("screen.png")
        let plan = try capturePlan(image: image)
        let capture = try run(plan)
        if plan.jsonOutput { _ = try JSONSerialization.jsonObject(with: capture) }
        let geometry = try ScreenImage.inspect(image)
        let capturedAt = Date().ISO8601Format()
        var diagnostics: [String] = []
        if mode != .ocr {
            do {
                let data = try await hierarchy()
                guard try Self.hasUsefulPhysicalHierarchy(data) else {
                    throw CommandFailure(.targetUnresolved, "Accessibility returned no labeled or identified non-application nodes.", inputSent: .none)
                }
                if let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for key in ["cleanup", "connectionCleanup"] {
                        if let cleanup = tree[key] as? [String: Any] {
                            if let warning = cleanup["warning"] as? String { diagnostics.append(warning) }
                            if cleanup["confirmed"] as? Bool == false {
                                diagnostics.append("\(key) unconfirmed: \(cleanup["diagnostic"] as? String ?? "No independent cleanup confirmation.")")
                            }
                        }
                    }
                }
                return try result(image: image, geometry: geometry, capturedAt: capturedAt, method: "accessibility", hierarchy: data, diagnostics: diagnostics)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if mode == .tree { throw CommandFailure("Hierarchy unavailable: \(error). Screenshot saved at \(image.path)", wrapping: error) }
                diagnostics.append("Accessibility unavailable: \(String(String(describing: error).prefix(2000)))")
            }
        }
        try Task.checkCancellation()
        do {
            let text = try await recognize(image.path)
            try Task.checkCancellation()
            if text.regions.isEmpty { diagnostics.append("OCR returned no recognized text; the image remains available.") }
            return try result(image: image, geometry: geometry, capturedAt: capturedAt, method: "ocr", text: text, diagnostics: diagnostics)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if mode == .ocr { throw CommandFailure("OCR unavailable: \(error). Screenshot saved at \(image.path)", wrapping: error) }
            diagnostics.append("OCR unavailable: \(String(String(describing: error).prefix(2000)))")
            return try result(image: image, geometry: geometry, capturedAt: capturedAt, method: "image-only", diagnostics: diagnostics)
        }
    }

    static func hasUsefulPhysicalHierarchy(_ data: Data) throws -> Bool {
        guard let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              tree["format"] as? String == "accessibility-tree", tree["parsedHierarchy"] as? Bool == true,
              tree["coordinateSpace"] as? String == "device-logical-points",
              ["centre-hit-test", AccessibilityPlatform.simulator.selection].contains((tree["application"] as? [String: Any])?["selection"] as? String ?? ""),
              let nodes = tree["nodes"] as? [[String: Any]], tree["nodeCount"] as? Int == nodes.count else { return false }
        return nodes.dropFirst().contains { node in
            node["visible"] as? Bool != false && ["label", "identifier", "value"].contains { !(node[$0] as? String ?? "").isEmpty }
        }
    }

    private func result(image: URL, geometry: ScreenImage, capturedAt: String, method: String,
                        hierarchy: Data? = nil, text: ScreenText? = nil, diagnostics: [String]) throws -> Data {
        var result: [String: Any] = ["platform": platform, "device": device, "method": method,
            "status": method == "image-only" ? "partial" : "captured", "imagePath": image.path,
            "image": ["width": geometry.width, "height": geometry.height, "format": "png"],
            "capturedAt": capturedAt, "diagnostics": diagnostics,
            "coordinateSpace": method == "accessibility" ? "device-logical-points" : (method == "ocr" ? "normalized-top-left" : "image-pixels")]
        if let hierarchy { result["hierarchy"] = try JSONSerialization.jsonObject(with: hierarchy) }
        if let text { result["textRegions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text.regions)) }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}

extension ScreenCommand {
    /// `mode` defaults to auto; a simulator is addressed by UUID only.
    init(platform: String, device: String, mode: String?) throws {
        guard !device.isEmpty, !device.hasPrefix("-"), let mode = Mode(rawValue: mode ?? "auto"),
              platform != "simulator" || UUID(uuidString: device) != nil else {
            throw CommandFailure.usage("Usage: screen [auto|tree|ocr] (--device <UDID> | --simulator <UUID>). Simulator screen requires an explicit UUID.")
        }
        self.init(platform: platform, device: device, mode: mode)
    }
}

struct ScreenImage: Sendable {
    let width: Int
    let height: Int
    static func inspect(_ url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), type as String == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
            throw CommandFailure(.toolFailed, "Capture did not produce a decodable PNG: \(url.path)", inputSent: .none)
        }
        return Self(width: image.width, height: image.height)
    }
}
