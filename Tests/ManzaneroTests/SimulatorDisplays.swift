import Foundation
import MCP
import Testing
@testable import Manzanero

/// Simulator display listing and the display choice of captures.
struct SimulatorDisplaysTests {
    static let uuid = SimulatorDeviceTests.uuid

    static func display(_ id: Int, _ name: String, device: String, primary: Bool = false, kind: String = "integrated",
                        size: [Double] = [0, 0], nativeSize: [Double]? = nil, backlight: String = "off", active: Bool = false) -> [String: Any] {
        ["displayId": id, "name": name, "deviceName": device, "primary": primary, "type": [kind: [String: Any]()],
         "nativeSize": nativeSize ?? size, "currentMode": ["size": size, "preferredUIScale": 3], "pointScale": 3, "backlightState": backlight, "active": active, "currentOrientation": "rot0",
         "nativeOrientation": "rot0", "uniqueId": "AAAAAAAA-0000-4000-8000-00000000000\(id)"]
    }

    static func json(_ displays: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["displays": displays]], options: [.sortedKeys])
    }

    /// The iPhone Duo's display information (iOS 27.2 runtime; trimmed, placeholder identifiers).
    static let duo = json([
        display(1, "LCD", device: "primary", primary: true, size: [1398, 2034], backlight: "activeOn", active: true),
        display(2, "TVOut", device: "external-0", kind: "external"),
        display(3, "LCD-1", device: "primary-1", size: [2007, 2853], backlight: "activeOn"),
        display(4, "Wireless", device: "wireless0", kind: "wireless"),
        display(5, "Resizable", device: "resizable", kind: "virtual")])

    /// An Apple TV (tvOS 27.2): one external display whose nativeSize is
    /// 0 × 0 while its current mode is 1920 × 1080, and whose backlight reads off.
    static let television = json([display(1, "TVOut", device: "external-0", primary: true, kind: "external", size: [1920, 1080],
                                          nativeSize: [0, 0])])

    static func environment(_ data: Data, reads: Counter = Counter()) -> SimulatorEnvironment {
        var environment = SimulatorEnvironment(lookup: { _ in SimulatorDeviceTests.info() },
                                               accessibility: { _, _ in Issue.record("Displays opened accessibility"); return SimulatorAXFixture().session() })
        environment.displayInfo = { device in
            #expect(device == uuid)
            reads.value += 1
            return data
        }
        return environment
    }

    final class Counter: @unchecked Sendable { var value = 0 }

    @Test func duoListsTwoCapturableIntegratedDisplays() throws {
        let displays = try SimulatorDisplays.parse(Self.duo)
        #expect(displays.map(\.name) == ["LCD", "TVOut", "LCD-1", "Wireless", "Resizable"])
        #expect(displays.filter(\.capturable).map(\.id) == [1, 3])
        let inner = try #require(displays.first { $0.id == 3 })
        #expect(inner.kind == "integrated" && !inner.primary && inner.deviceName == "primary-1" && inner.json["widthPoints"] as? Double == 669)
    }

    @Test func primaryDisplayIsTheDefaultOnlyWhenSeveralCanBeCaptured() throws {
        let duo = try SimulatorDisplays.select(nil, in: SimulatorDisplays.parse(Self.duo))
        #expect(duo.display.name == "LCD" && duo.argument == "--display=1")
        // One capturable display: the simctl invocation is unchanged.
        let television = try SimulatorDisplays.select(nil, in: SimulatorDisplays.parse(Self.television))
        #expect(television.display.name == "TVOut" && television.argument == nil)
    }

    @Test(arguments: ["LCD-1", "lcd-1", "primary-1", "3"])
    func displayIsChosenByNameDeviceNameOrScreenID(_ requested: String) throws {
        let selection = try SimulatorDisplays.select(requested, in: SimulatorDisplays.parse(Self.duo))
        #expect(selection.display.id == 3 && selection.argument == "--display=3")
    }

    @Test(arguments: ["LCD-2", "TVOut", "9", "Resizable"])
    func unknownOrUncapturableDisplayIsRefused(_ requested: String) throws {
        let failure = try #require(throws: CommandFailure.self) { try SimulatorDisplays.select(requested, in: SimulatorDisplays.parse(Self.duo)) }
        #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
        #expect(failure.description.contains("LCD (id 1, primary), LCD-1 (id 3)"))
    }

    @Test func displayArgumentGoesBeforeThePath() throws {
        let selection = SimulatorDisplaySelection(display: SimulatorDisplayEntry(id: 3, name: "LCD-1", deviceName: "primary-1", primary: false,
            kind: "integrated", widthPixels: 1, heightPixels: 1, pointScale: 3, backlight: "activeOn", active: false, orientation: "rot0"),
            argument: "--display=3")
        #expect(SimulatorDisplays.arguments(["simctl", "io", "U", "screenshot", "--type=png", "a.png"], selection: selection)
                == ["simctl", "io", "U", "screenshot", "--type=png", "--display=3", "a.png"])
        #expect(SimulatorDisplays.arguments(["simctl", "io", "U", "screenshot", "a.png"], selection: nil) == ["simctl", "io", "U", "screenshot", "a.png"])
        var recording = RecordingCommand(physical: false, device: "U", destination: URL(fileURLWithPath: "tmp/a.mp4"), seconds: 2, codec: "h264", native: false)
        recording.selection = selection
        #expect(try recording.command(staging: URL(fileURLWithPath: "/s/c.mp4")).arguments
                == ["simctl", "io", "U", "recordVideo", "--codec=h264", "--display=3", "/s/c.mp4"])
    }

    // MARK: - Parsing

    @Test func displayOptionIsParsedForSimulatorCaptures() throws {
        #expect(try request(["screenshot", "tmp/a.png", "--simulator", Self.uuid, "--display", "LCD-1"])
                == .simulatorDisplay(.screenshot(device: Self.uuid, output: "tmp/a.png", display: "LCD-1")))
        #expect(try request(["screenshot", "tmp/a.png", "--simulator", Self.uuid])
                == .simulatorDisplay(.screenshot(device: Self.uuid, output: "tmp/a.png", display: nil)))
        guard case .screen(let screen) = try request(["screen", "ocr", "--simulator", Self.uuid, "--display", "3"]),
              case .record(let recording) = try request(["record", "tmp/a.mp4", "2", "--simulator", Self.uuid, "--display=primary-1"]) else {
            Issue.record("screen or record built another request"); return
        }
        #expect(screen.display == "3" && screen.mode == .ocr && recording.display == "primary-1")
        #expect(try request(["displays", "--simulator", Self.uuid]) == .simulatorDisplay(.list(device: Self.uuid)))
        #expect(try request(["displays", "--simulator", Self.uuid]).isReadOnly)
        #expect(try request(["screenshot", "tmp/a.png", "--simulator", Self.uuid, "--display", "3"]).isReadOnly)
    }

    @Test func displayOptionIsRefusedBeforeAnyDeviceContact() throws {
        for args in [["screenshot", "tmp/a.png", "--device", "phone", "--display", "1"], ["screen", "--device", "phone", "--display", "1"],
                     ["record", "tmp/a.mp4", "2", "--device", "phone", "--display", "1"], ["displays", "--device", "phone"]] {
            let failure = try #require(throws: CommandFailure.self) { try request(args) }
            #expect(failure.code == .unsupportedOperation && failure.inputSent == .none)
        }
        for value in ["", String(repeating: "x", count: 65), "a\nb"] {
            let failure = try #require(throws: CommandFailure.self) { try request(["screenshot", "tmp/a.png", "--simulator", Self.uuid, "--display=\(value)"]) }
            #expect(failure.code == .usage)
        }
        let named = try #require(throws: CommandFailure.self) { try request(["displays", "--simulator", "booted"]) }
        #expect(named.code == .usage)
    }

    // MARK: - Execution

    @Test func listingReportsEveryDisplayAndTheDefault() throws {
        let data = try SimulatorDisplayRequest.list(device: Self.uuid).execute(environment: Self.environment(Self.duo), run: { _ in
            Issue.record("Listing ran a tool"); return Data()
        })
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let displays = try #require(root["displays"] as? [[String: Any]])
        #expect(displays.count == 5 && root["defaultCaptureDisplay"] as? Int == 1)
        #expect(displays[2]["name"] as? String == "LCD-1" && displays[2]["capturable"] as? Bool == true && displays[2]["primary"] as? Bool == false)
        #expect(displays[2]["backlightState"] as? String == "activeOn" && displays[2]["active"] as? Bool == false)
    }

    @Test func screenshotPassesTheChosenScreenID() throws {
        var ran: [[String]] = []
        for (data, requested, expected) in [(Self.duo, nil, "--display=1"), (Self.duo, "LCD-1", "--display=3"), (Self.television, nil, nil)] as [(Data, String?, String?)] {
            _ = try SimulatorDisplayRequest.screenshot(device: Self.uuid, output: "tmp/a.png", display: requested)
                .execute(environment: Self.environment(data), run: { ran.append($0.arguments); return Data() })
            let base = ["simctl", "io", Self.uuid, "screenshot", "--type=png"]
            #expect(ran.last == base + (expected.map { [$0] } ?? []) + ["tmp/a.png"])
        }
        let unknown = try #require(throws: CommandFailure.self) {
            try SimulatorDisplayRequest.screenshot(device: Self.uuid, output: "tmp/a.png", display: "LCD-9")
                .execute(environment: Self.environment(Self.duo), run: { _ in Issue.record("Captured an unknown display"); return Data() })
        }
        #expect(unknown.code == .targetUnresolved)
    }

    @Test func dryRunsDoNotReadTheDisplays() async throws {
        let reads = Counter()
        let service = CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: Self.environment(Self.duo, reads: reads),
                                     readinessQuery: { _ in Issue.record("Dry run queried CoreDevice"); return Data() })
        for args in [["screenshot", "tmp/a.png", "--simulator", Self.uuid, "--display", "LCD-1"], ["displays", "--simulator", Self.uuid],
                     ["screen", "--simulator", Self.uuid, "--display", "LCD-1"], ["record", "tmp/new.mp4", "2", "--simulator", Self.uuid, "--display", "3"]] {
            let plan = try SimulatorInputTests.json(try await service.run(args, dryRun: true))
            let display = plan["display"] as? [String: Any]
            if args[0] == "displays" {
                #expect(plan["readOnly"] as? Bool == true && display == nil)
            } else {
                let resolution = display?["resolution"] as? String ?? ""
                let expected = SimulatorDisplays.resolution
                #expect(resolution.hasPrefix(expected))
            }
        }
        #expect(reads.value == 0)
    }

    @Test func screenTreeRefusesANonPrimaryDisplayBeforeCapture() async throws {
        var screen = ScreenCommand(platform: "simulator", device: Self.uuid, mode: .tree)
        screen.selection = try SimulatorDisplays.select("LCD-1", in: SimulatorDisplays.parse(Self.duo))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/test-screen-\(UUID().uuidString)")
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await screen.execute(directory: directory, run: { _ in Issue.record("Captured"); return Data() },
                                         hierarchy: { Issue.record("Read a tree"); return Data() })
        }
        #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
        #expect(try screen.capturePlan(image: URL(fileURLWithPath: "/s/screen.png")).arguments.contains("--display=3"))
    }

    @Test func mcpToolsCarryTheDisplay() throws {
        func tool(_ name: String) throws -> MCPToolDefinition { try #require(MCPTools.definitions.first { $0.name == name }) }
        let device: Value = .string(Self.uuid)
        #expect(try tool("screenshot").command(["platform": "simulator", "device": device, "path": "tmp/a.png", "display": "LCD-1"])
                == ["screenshot", "--simulator=\(Self.uuid)", "--display=LCD-1", "--", "tmp/a.png"])
        #expect(try tool("get_screen").command(["platform": "simulator", "device": device, "display": "3"])
                == ["screen", "--simulator=\(Self.uuid)", "--display=3", "--", "auto"])
        #expect(try tool("record_screen").command(["platform": "simulator", "device": device, "path": "tmp/a.mp4", "seconds": 2, "display": "3"])
                == ["record", "--simulator=\(Self.uuid)", "--display=3", "--", "tmp/a.mp4", "2", "h264"])
        let list = try tool("list_displays")
        let listed = try list.command(["device": device])
        #expect(list.readOnly && listed == ["displays", "--simulator=\(Self.uuid)"])
        #expect(try request(list.command(["device": device])) == .simulatorDisplay(.list(device: Self.uuid)))
    }
}
