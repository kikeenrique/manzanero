import Foundation

/// `last-crash --symbols <path>`: frames of the found report resolved with
/// Apple's `atos` against the app's own symbols, on the Mac.
///
/// A report carries offsets into each image and, for most system frames, a
/// symbol; a release build's own frames have none, and a simulator's have no
/// file or line. The given `.dSYM`, `.app` or Mach-O file is read for its
/// UUIDs (`dwarfdump --uuid`); only an image of the report with the same UUID
/// and architecture is resolved, one `atos` call per image, so symbols of
/// another build never name a frame. Nothing is sent to a device.
enum CrashSymbolication {
    struct Binary: Equatable {
        let uuid: String
        let arch: String
        let path: String
    }

    /// The Mach-O files a path offers: a `.dSYM`'s DWARF files; an `.app`'s
    /// executable, its `*.debug.dylib` and its frameworks' executables; or
    /// the path itself.
    static func files(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        switch url.pathExtension {
        case "dSYM":
            let dwarf = url.appendingPathComponent("Contents/Resources/DWARF")
            return ((try? manager.contentsOfDirectory(atPath: dwarf.path)) ?? []).sorted().map { dwarf.appendingPathComponent($0).path }
        case "app":
            var found: [String] = []
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            if let executable = info?["CFBundleExecutable"] as? String { found.append(url.appendingPathComponent(executable).path) }
            for name in ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).sorted() where name.hasSuffix(".debug.dylib") {
                found.append(url.appendingPathComponent(name).path)
            }
            let frameworks = url.appendingPathComponent("Frameworks")
            for name in ((try? manager.contentsOfDirectory(atPath: frameworks.path)) ?? []).sorted() where name.hasSuffix(".framework") {
                found.append(frameworks.appendingPathComponent(name).appendingPathComponent((name as NSString).deletingPathExtension).path)
            }
            return found.filter { manager.fileExists(atPath: $0) }
        default:
            return [path]
        }
    }

    /// `UUID: 4A2256B7-839A-39D5-B64B-94EC9256BFF8 (arm64) /path` lines.
    static func parseUUIDs(_ text: String) -> [Binary] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "UUID:", UUID(uuidString: parts[1]) != nil,
                  parts[2].hasPrefix("("), parts[2].hasSuffix(")") else { return nil }
            return Binary(uuid: parts[1].uppercased(), arch: String(parts[2].dropFirst().dropLast()), path: parts[3])
        }
    }

    /// `symbol (in image) (file:line)`, atos's form; the location only when
    /// it names a real place.
    static func parseLine(_ line: String) -> (symbol: String, location: String?)? {
        guard let inRange = line.range(of: " (in ") else { return nil }
        let symbol = String(line[..<inRange.lowerBound])
        var location: String?
        if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards), open.lowerBound > inRange.lowerBound {
            let inside = String(line[open.upperBound..<line.index(before: line.endIndex)])
            if inside.contains(":"), !inside.contains("<compiler-generated>"), !inside.hasPrefix("in ") { location = inside }
        }
        return (symbol, location)
    }

    /// The summary with `symbols` and, on each frame resolved, `atos` (the
    /// line as atos wrote it), `sourceLocation` when it has one, and `symbol`
    /// when the report had none.
    static func apply(_ summary: [String: Any], report: IPSReport, symbols path: String,
                      maxFrames: Int = LastCrashQuery.maxFrames, run: (DeviceCommand) throws -> Data) throws -> [String: Any] {
        let files = files(path)
        guard !files.isEmpty else { throw CommandFailure.usage("--symbols found no Mach-O file in \(path): give a .dSYM, an .app or a binary.") }
        let binaries = parseUUIDs(String(decoding: try run(DeviceCommand(arguments: ["dwarfdump", "--uuid"] + files, jsonOutput: false)), as: UTF8.self))
        let images = report.body["usedImages"] as? [[String: Any]] ?? []
        // Each report image whose UUID and architecture one of the binaries has.
        var matched: [Int: Binary] = [:]
        for (index, image) in images.enumerated() {
            guard let uuid = (image["uuid"] as? String)?.uppercased() else { continue }
            let arch = image["arch"] as? String
            if let binary = binaries.first(where: { $0.uuid == uuid && (arch == nil || $0.arch == arch) }) { matched[index] = binary }
        }
        // The frames the summary shows, in its order, from the report.
        let threads = report.body["threads"] as? [[String: Any]] ?? []
        let faulting = (report.body["faultingThread"] as? NSNumber)?.intValue
        var lists: [(key: String, frames: [[String: Any]])] = []
        if let faulting, threads.indices.contains(faulting) {
            lists.append(("faultingThread", Array((threads[faulting]["frames"] as? [[String: Any]] ?? []).prefix(maxFrames))))
        }
        if let backtrace = report.body["lastExceptionBacktrace"] as? [[String: Any]] {
            lists.append(("lastExceptionBacktrace", Array(backtrace.prefix(maxFrames))))
        }
        // One atos call per image, for every address of it in those frames.
        var resolved: [String: (symbol: String, location: String?, line: String)] = [:]
        for (index, binary) in matched.sorted(by: { $0.key < $1.key }) {
            guard let base = (images[index]["base"] as? NSNumber)?.uint64Value else { continue }
            var offsets: [UInt64] = []
            for list in lists {
                for frame in list.frames where (frame["imageIndex"] as? NSNumber)?.intValue == index {
                    if let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value, !offsets.contains(offset) { offsets.append(offset) }
                }
            }
            guard !offsets.isEmpty else { continue }
            let output = try run(DeviceCommand(arguments: ["atos", "-o", binary.path, "-arch", binary.arch, "-l", hex(base)]
                + offsets.map { hex(base + $0) }, jsonOutput: false))
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (offset, line) in zip(offsets, lines) {
                if let parsed = parseLine(line) { resolved["\(index):\(offset)"] = (parsed.symbol, parsed.location, line) }
            }
        }
        var summary = summary
        var count = 0
        func annotate(_ shown: [[String: Any]], _ original: [[String: Any]]) -> [[String: Any]] {
            zip(shown, original).map { shown, original in
                var frame = shown
                guard let index = (original["imageIndex"] as? NSNumber)?.intValue,
                      let offset = (original["imageOffset"] as? NSNumber)?.uint64Value,
                      let found = resolved["\(index):\(offset)"] else { return frame }
                count += 1
                frame["atos"] = found.line
                if let location = found.location { frame["sourceLocation"] = location }
                if frame["symbol"] == nil { frame["symbol"] = found.symbol }
                return frame
            }
        }
        for list in lists {
            if list.key == "faultingThread", var thread = summary["faultingThread"] as? [String: Any],
               let shown = thread["frames"] as? [[String: Any]] {
                thread["frames"] = annotate(shown, list.frames)
                summary["faultingThread"] = thread
            } else if list.key == "lastExceptionBacktrace", let shown = summary["lastExceptionBacktrace"] as? [[String: Any]] {
                summary["lastExceptionBacktrace"] = annotate(shown, list.frames)
            }
        }
        summary["symbolicated"] = count > 0
        var report: [String: Any] = [
            "path": path, "framesResolved": count,
            "matchedImages": matched.sorted { $0.key < $1.key }.map { images[$0.key]["name"] as? String ?? $0.value.path },
            "givenUUIDs": binaries.map { "\($0.uuid) (\($0.arch))" },
        ]
        if matched.isEmpty {
            report["note"] = "No image of the report has the UUID and architecture of a given binary, so nothing was resolved: the symbols are from another build."
        }
        summary["symbols"] = report
        return summary
    }

    static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
}
