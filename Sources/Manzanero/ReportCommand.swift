import Foundation

enum ReportCommand {
    static func plan(operation: String, operands: [String]) throws -> [String]? {
        guard operation == "reports" || operation == "report" else { return nil }
        let domain = ["--domain-type", "systemCrashLogs"]
        if operation == "reports" {
            guard operands.count <= 1 else { throw CommandFailure.usage("Usage: reports [relative-directory]") }
            let path = operands.first ?? "."
            try ScopedDevicePath.validate(path)
            return ["info", "files"] + domain + ["--subdirectory", path, "--no-recurse"]
        }
        guard operands.count == 2, !operands[1].isEmpty, !operands[1].hasPrefix("-") else {
            throw CommandFailure.usage("Usage: report <relative-report-path> <local-destination>")
        }
        try ScopedDevicePath.validate(operands[0])
        return ["copy", "from"] + domain + ["--source", operands[0], "--destination", operands[1]]
    }
}
