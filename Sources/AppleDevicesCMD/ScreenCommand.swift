import Foundation
import ImageIO

struct ScreenCommand: Sendable {
    enum Mode: String, Sendable { case automatic = "auto", tree, ocr }
    let platform: String
    let device: String
    let mode: Mode

    static func parse(_ args: [String]) throws -> Self? {
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), args[2] == "screen" else { return nil }
        guard (3...4).contains(args.count), !args[1].isEmpty, !args[1].hasPrefix("-"),
              let mode = Mode(rawValue: args.count == 4 ? args[3] : "auto"),
              args[0] != "simulator" || UUID(uuidString: args[1]) != nil else {
            throw CommandFailure(description: "Usage: <physical|simulator> <device> screen [auto|tree|ocr]. Simulator screen requires an explicit UUID.")
        }
        return Self(platform: args[0], device: args[1], mode: mode)
    }

    func capturePlan(image: URL) throws -> DeviceCommand {
        guard let plan = try DeviceCommand.parse([platform, device, "screenshot", image.path]) else {
            throw CommandFailure(description: "Cannot plan screen capture.")
        }
        return plan
    }

    func execute(directory: URL, run: (DeviceCommand) throws -> Data,
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
                guard let tree = try DeviceCommand.parse([platform, device, "tree"]) else { throw CommandFailure(description: "Cannot plan hierarchy query.") }
                let data = try run(tree)
                guard try platform == "physical" ? Self.hasUsefulPhysicalHierarchy(data) : Self.hasUsefulHierarchy(data) else {
                    throw CommandFailure(description: "Accessibility returned no labeled or identified non-application nodes.")
                }
                if platform == "physical",
                   let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cleanup = tree["cleanup"] as? [String: Any],
                   let warning = cleanup["warning"] as? String {
                    diagnostics.append(warning)
                }
                return try result(image: image, geometry: geometry, capturedAt: capturedAt, method: "accessibility", hierarchy: data, diagnostics: diagnostics)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if mode == .tree { throw CommandFailure(description: "Hierarchy unavailable: \(error). Screenshot saved at \(image.path)") }
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
            if mode == .ocr { throw CommandFailure(description: "OCR unavailable: \(error). Screenshot saved at \(image.path)") }
            diagnostics.append("OCR unavailable: \(String(String(describing: error).prefix(2000)))")
            return try result(image: image, geometry: geometry, capturedAt: capturedAt, method: "image-only", diagnostics: diagnostics)
        }
    }

    static func hasUsefulHierarchy(_ data: Data) throws -> Bool {
        let value = try JSONSerialization.jsonObject(with: data)
        var nodes = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        while let node = nodes.popLast() {
            if let children = node["children"] as? [[String: Any]] { nodes.append(contentsOf: children) }
            let role = (node["role"] as? String ?? node["type"] as? String ?? "").lowercased()
            if !role.isEmpty, role != "axapplication", role != "application",
               ["AXLabel", "AXUniqueId", "AXValue", "title"].contains(where: { !(node[$0] as? String ?? "").isEmpty }) { return true }
        }
        return false
    }

    static func hasUsefulPhysicalHierarchy(_ data: Data) throws -> Bool {
        guard let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              tree["format"] as? String == "accessibility-tree", tree["parsedHierarchy"] as? Bool == true,
              tree["coordinateSpace"] as? String == "device-logical-points",
              (tree["application"] as? [String: Any])?["selection"] as? String == "centre-hit-test",
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
            "coordinateSpace": method == "accessibility" ? (platform == "physical" ? "device-logical-points" : "interface-points") : (method == "ocr" ? "normalized-top-left" : "image-pixels")]
        if let hierarchy { result["hierarchy"] = try JSONSerialization.jsonObject(with: hierarchy) }
        if let text { result["textRegions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text.regions)) }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}

struct ScreenImage: Sendable {
    let width: Int
    let height: Int
    static func inspect(_ url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), type as String == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
            throw CommandFailure(description: "Capture did not produce a decodable PNG: \(url.path)")
        }
        return Self(width: image.width, height: image.height)
    }
}
