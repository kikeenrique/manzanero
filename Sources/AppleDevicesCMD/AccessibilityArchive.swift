import Foundation
import Darwin

/// Saves raw protocol evidence without placing a device UI archive in normal stdout.
enum AccessibilityArchive {
    static func validateDestination(_ path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw CommandFailure(description: "Accessibility archive destination already exists: \(path)")
        }
        var directory: ObjCBool = false
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &directory), directory.boolValue else {
            throw CommandFailure(description: "Accessibility archive parent directory must exist: \(parent)")
        }
    }

    static func save(_ output: Data, to path: String) throws -> Data {
        guard output.count <= 24 * 1024 * 1024,
              var result = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              result["format"] as? String == "nskeyedarchive-base64",
              let encoded = result["archive"] as? String,
              let archive = Data(base64Encoded: encoded), archive.count <= 16 * 1024 * 1024,
              archive.starts(with: Data("bplist00".utf8)) || archive.starts(with: Data("<?xml".utf8)) else {
            throw CommandFailure(description: "Backend returned an invalid or oversized accessibility archive.")
        }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CommandFailure(description: "Cannot create accessibility archive without overwriting: \(destination.path) (errno \(errno))")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? file.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try file.write(contentsOf: archive)
        try file.close()
        result.removeValue(forKey: "archive")
        result["archivePath"] = destination.path
        result["archiveBytes"] = archive.count
        result["format"] = "nskeyedarchive-file"
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        completed = true
        return data
    }
}
