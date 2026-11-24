import Foundation
import MCP
import Testing
@testable import Manzanero

/// `last-crash --symbols`: only images whose UUID a given binary has are
/// resolved, with one atos call each, and the frames say what atos said.
struct CrashSymbolicationTests {
    static let appUUID = "4A2256B7-839A-39D5-B64B-94EC9256BFF8"

    /// A report whose crashed thread has two frames in the app and one in
    /// libswiftCore, and whose last exception backtrace repeats one.
    static func report() throws -> IPSReport {
        let header = try JSONSerialization.data(withJSONObject: ["bug_type": "309", "bundleID": "com.example.app"])
        let body = try JSONSerialization.data(withJSONObject: [
            "usedImages": [["uuid": "11111111-2222-3333-4444-555555555555", "arch": "arm64", "base": 4096, "name": "libswiftCore.dylib"],
                           ["uuid": appUUID.lowercased(), "arch": "arm64", "base": 0x100000, "name": "App"]],
            "faultingThread": 0,
            "threads": [["frames": [["imageIndex": 0, "imageOffset": 16, "symbol": "_assertionFailure"],
                                    ["imageIndex": 1, "imageOffset": 0x40], ["imageIndex": 1, "imageOffset": 0x80]]]],
            "lastExceptionBacktrace": [["imageIndex": 1, "imageOffset": 0x40]],
        ] as [String: Any])
        return try IPSReport(header + Data("\n".utf8) + body)
    }

    /// An archive's `dSYMs` folder and the archive itself give the DWARF
    /// files of each `.dSYM` inside, not the folder.
    @Test func aFolderOfDSYMsAndAnArchiveGiveTheirDWARFFiles() throws {
        let root = URL(fileURLWithPath: "tmp/symbolication-\(UUID().uuidString)/App.xcarchive")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = root.appendingPathComponent("dSYMs")
        for name in ["App.app.dSYM", "Kit.framework.dSYM"] {
            let dwarf = folder.appendingPathComponent(name).appendingPathComponent("Contents/Resources/DWARF")
            try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
            try Data().write(to: dwarf.appendingPathComponent((name as NSString).deletingPathExtension.replacingOccurrences(of: ".app", with: "").replacingOccurrences(of: ".framework", with: "")))
        }
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        let fromFolder = CrashSymbolication.files(folder.path)
        #expect(fromFolder.count == 2 && fromFolder.allSatisfy { $0.contains(".dSYM/Contents/Resources/DWARF/") })
        #expect(CrashSymbolication.files(root.path) == fromFolder)
    }

    @Test func dwarfdumpAndAtosLinesAreRead() {
        let binaries = CrashSymbolication.parseUUIDs("UUID: \(Self.appUUID.lowercased()) (arm64) /x/App.app/App\nnot a line\nUUID: bad (arm64) /y")
        #expect(binaries == [.init(uuid: Self.appUUID, arch: "arm64", path: "/x/App.app/App")])
        let full = CrashSymbolication.parseLine("Model.load() (in App) (Model.swift:42)")
        #expect(full?.symbol == "Model.load()" && full?.location == "Model.swift:42")
        let generated = CrashSymbolication.parseLine("closure #1 in f() (in App.debug.dylib) (/<compiler-generated>:0)")
        #expect(generated?.symbol == "closure #1 in f()" && generated?.location == nil)
        #expect(CrashSymbolication.parseLine("0x100040") == nil)
    }

    @Test func onlyTheMatchingImageIsResolvedOnceWithEveryAddress() throws {
        let report = try Self.report()
        var calls: [[String]] = []
        let summary = try CrashSymbolication.apply(report.summary(), report: report, symbols: "/x/App") { command in
            calls.append(command.arguments)
            if command.arguments.first == "dwarfdump" { return Data("UUID: \(Self.appUUID) (arm64) /x/App\n".utf8) }
            return Data("Model.load() (in App) (Model.swift:42)\nApp.main() (in App) (main.swift:7)\n".utf8)
        }
        #expect(calls.count == 2)
        #expect(calls.last == ["atos", "-o", "/x/App", "-arch", "arm64", "-l", "0x100000", "0x100040", "0x100080"])
        let frames = try #require((summary["faultingThread"] as? [String: Any])?["frames"] as? [[String: Any]])
        // libswiftCore's frame keeps the report's symbol and gets no atos line.
        #expect(frames[0]["symbol"] as? String == "_assertionFailure" && frames[0]["atos"] == nil)
        #expect(frames[1]["symbol"] as? String == "Model.load()" && frames[1]["sourceLocation"] as? String == "Model.swift:42")
        #expect(frames[2]["symbol"] as? String == "App.main()" && frames[2]["sourceLocation"] as? String == "main.swift:7")
        let backtrace = try #require(summary["lastExceptionBacktrace"] as? [[String: Any]])
        #expect(backtrace[0]["sourceLocation"] as? String == "Model.swift:42")
        #expect(summary["symbolicated"] as? Bool == true)
        let symbols = try #require(summary["symbols"] as? [String: Any])
        #expect(symbols["framesResolved"] as? Int == 3 && symbols["matchedImages"] as? [String] == ["App"] && symbols["note"] == nil)
    }

    @Test func anotherBuildsSymbolsResolveNothingAndSaySo() throws {
        let report = try Self.report()
        var atos = 0
        let summary = try CrashSymbolication.apply(report.summary(), report: report, symbols: "/x/App") { command in
            if command.arguments.first == "atos" { atos += 1 }
            return Data("UUID: 0F08A0A8-79E9-3077-A0E7-6EE67CF5ABFE (arm64) /x/App\n".utf8)
        }
        #expect(atos == 0 && summary["symbolicated"] as? Bool == false)
        #expect(((summary["symbols"] as? [String: Any])?["note"] as? String)?.contains("another build") == true)
    }

    @Test func theOptionIsCheckedBeforeAnyDeviceAndReachesMCP() throws {
        let simulator = "1DCC0F91-CF8C-4774-BD9C-BC94AF982632"
        let failure = #expect(throws: CommandFailure.self) {
            try CLI.invocation(["last-crash", "--bundle", "com.example.app", "--symbols", "tmp/no-such.dSYM", "--simulator", simulator])
        }
        #expect(failure?.code == .usage)
        let tool = try #require(MCPTools.definitions.first { $0.name == "latest_crash" })
        let args = try tool.command(["device": .string(simulator), "platform": "simulator", "bundle_id": "com.example.app", "symbols": "Package.swift"])
        guard case .diagnostics(.lastCrash(let query)) = try CLI.invocation(args).request else { Issue.record("Not last-crash: \(args)"); return }
        #expect(query.symbols == "Package.swift")
    }
}
