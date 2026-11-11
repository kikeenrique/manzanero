import Foundation

/// App-container operations remain scoped to the bundle identifier given by the caller.
enum AppDataCommand {
    static func plan(operation: String, operands: [String]) throws -> [String]? {
        guard ["files", "pull", "push"].contains(operation) else { return nil }
        let expected = operation == "files" ? 2 : 3
        guard operands.count == expected, operands.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
            throw CommandFailure(description: "\(operation) expects \(expected) operands. See --help.")
        }
        let remotePath = operation == "push" ? operands[2] : operands[1]
        guard !remotePath.hasPrefix("/"), !remotePath.split(separator: "/").contains("..") else {
            throw CommandFailure(description: "Remote paths must be relative to the app container and cannot contain '..'. Use '.' for its root.")
        }
        let domain = ["--domain-type", "appDataContainer", "--domain-identifier", operands[0]]
        switch operation {
        case "files":
            return ["info", "files"] + domain + ["--subdirectory", remotePath, "--no-recurse"]
        case "pull":
            return ["copy", "from"] + domain + ["--source", remotePath, "--destination", operands[2]]
        default:
            return ["copy", "to"] + domain + ["--source", operands[1], "--destination", remotePath, "--remove-existing-content", "false"]
        }
    }
}
