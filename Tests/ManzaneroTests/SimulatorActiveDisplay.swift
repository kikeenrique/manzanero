import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

/// Touch, accessibility and captures follow the display the interface is on:
/// an unfolded iPhone Duo's inner display, while every other simulator (and
/// the folded Duo) keeps the primary-display behaviour.
@Suite(.cleansLeaseDirectories)
struct SimulatorActiveDisplayTests {
    static let uuid = SimulatorDeviceTests.uuid
    static let outer = "AAAAAAAA-0000-4000-8000-000000000001"
    static let inner = "AAAAAAAA-0000-4000-8000-000000000003"

    /// The Duo's display information as dtdeviceinfod reports it (iOS 27.2,
    /// trimmed, placeholder identifiers). Unfolded: LCD off, LCD-1 awake in
    /// rot90 and the device in landscape right.
    static func duo(unfolded: Bool, outerBacklight: String? = nil) -> Data {
        func display(_ id: Int, _ name: String, _ device: String, primary: Bool, size: [Double], backlight: String,
                     current: String, unique: String, kind: String = "integrated") -> [String: Any] {
            ["displayId": id, "name": name, "deviceName": device, "primary": primary, "type": [kind: [String: Any]()],
             "nativeSize": size, "currentMode": ["size": size], "bounds": [[0, 0], size], "pointScale": 3,
             "backlightState": backlight, "active": backlight == "activeOn", "nativeOrientation": "rot0",
             "currentOrientation": current, "uniqueId": unique]
        }
        let displays = [
            display(1, "LCD", "primary", primary: true, size: [1398, 2034], backlight: outerBacklight ?? (unfolded ? "off" : "activeOn"),
                    current: "rot0", unique: outer),
            display(3, "LCD-1", "primary-1", primary: false, size: [2007, 2853], backlight: unfolded ? "activeOn" : "off",
                    current: "rot90", unique: inner),
            display(5, "Resizable", "resizable", primary: false, size: [0, 0], backlight: "off", current: "rot0",
                    unique: "AAAAAAAA-0000-4000-8000-000000000005", kind: "virtual")]
        let root: [String: Any] = ["info": ["outcome": "success"], "result": ["displays": displays,
            "orientation": ["currentDeviceNonFlatOrientation": unfolded ? "landscapeRight" : "portrait"]]]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static let duoInfo = SimulatorDeviceTests.info(width: 466, height: 678, scale: 3)

    static func service(_ sent: SimulatorInputTests.Sent, _ display: Data) -> CommandService {
        sent.displays = [display]
        var environment = SimulatorInputTests.environment(sent)
        environment.lookup = { _ in sent.lookups += 1; return Self.duoInfo }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    // MARK: - The interface display

    @Test func unfoldedDuoUsesTheInnerDisplaysGeometryAndRotation() throws {
        let display = try SimulatorDisplay(Self.duo(unfolded: true))
        #expect(!display.isPrimary && display.displayUUID == Self.inner && display.rotation == 90 && display.backlight == "activeOn")
        #expect(display.secondary?.id == 3 && display.secondary?.name == "LCD-1")
        let ax = display.accessibility(Self.duoInfo)
        #expect(ax.bounds.width == 951 && ax.bounds.height == 669 && ax.pointScale == 3 && ax.orientation == "rot90")
        let screen = display.screenJSON(Self.duoInfo)
        #expect(screen["widthPoints"] as? Double == 669 && screen["interfaceWidthPoints"] as? Double == 951)
        #expect((screen["display"] as? [String: Any])?["name"] as? String == "LCD-1")
        let touch = try display.touch()
        #expect(touch.id == 3 && touch.rotation == 90 && touch.width == 2007)
    }

    @Test func foldedDuoAndSingleDisplaysKeepThePrimaryDisplay() throws {
        for data in [Self.duo(unfolded: false), SimulatorInputTests.displayJSON(),
                     // Both integrated displays awake (folding, fresh boot): primary.
                     Self.duo(unfolded: true, outerBacklight: "activeOn")] {
            let display = try SimulatorDisplay(data)
            #expect(display.isPrimary && display.secondary == nil && display.displayUUID == Self.outer)
            #expect(display.screenJSON(Self.duoInfo)["display"] == nil)
            #expect(try display.touch() == DirectTouchDisplay(data))
        }
        // The primary display off with an awake display that has no
        // framebuffer (the fixture's Resizable) stays the primary: display-off.
        let dark = try SimulatorDisplay(SimulatorInputTests.displayJSON(backlight: "off"))
        #expect(dark.isPrimary)
        let failure = try #require(throws: CommandFailure.self) { try dark.touch() }
        #expect(failure.code == .displayOff)
    }

    @Test func physicalTouchDisplayFollowsTheInterfaceWithoutADisplayID() throws {
        let data = Self.duo(unfolded: true)
        // Without an ID the display the interface is on, as on a physical
        // Duo unfolded (2026-11-25): the inner display.
        #expect(try DirectTouchDisplay(data).id == 3)
        #expect(try DirectTouchDisplay(data, displayId: 3).rotation == 90)
        let off = try #require(throws: CommandFailure.self) { try DirectTouchDisplay(Self.duo(unfolded: false), displayId: 3) }
        #expect(off.code == .displayOff && off.description.contains("Display is off."))
    }

    // MARK: - Touch

    @Test func touchOnTheInnerDisplayGoesToItsUniversalHIDTouchscreen() async throws {
        let sent = SimulatorInputTests.Sent()
        let receipt = try SimulatorInputTests.json(await Self.service(sent, Self.duo(unfolded: true))
            .run(["tap", "0.25", "0.75", "--simulator", Self.uuid]))
        #expect(sent.touches.isEmpty && sent.twoContacts.isEmpty && sent.reports.count == 1)
        let report = try #require(sent.reports.first)
        #expect(report.display == Self.inner && report.times.first == 0 && report.bytes.count == 58 * report.times.count)
        // Measured: interface (0.25, 0.75) on rot90 is the touchscreen's (0.75, 0.75).
        let first = SimulatorInputTests.contacts(report.bytes[0..<58])
        #expect(first.count == 1 && abs(first[0]!.0 - 0.75) < 0.0001 && abs(first[0]!.1 - 0.75) < 0.0001)
        #expect(SimulatorInputTests.contacts(report.bytes[(report.bytes.count - 58)...]).isEmpty)
        #expect(receipt["route"] as? String == "universal-hid" && receipt["displayRotationDegrees"] as? Int == 90)
        #expect(((receipt["screen"] as? [String: Any])?["display"] as? [String: Any])?["id"] as? Int == 3)
    }

    @Test func pinchOnTheInnerDisplaySendsBothContactsAsReports() async throws {
        let sent = SimulatorInputTests.Sent()
        _ = try await Self.service(sent, Self.duo(unfolded: true)).run(["pinch", "0.5", "0.5", "0.2", "0.5", "0.5", "--simulator", Self.uuid])
        let report = try #require(sent.reports.first)
        #expect(sent.twoContacts.isEmpty && SimulatorInputTests.contacts(report.bytes[0..<58]).count == 2)
    }

    /// The same requests as before for the folded Duo and a one-display phone:
    /// the Indigo schedule planned with the physical primary-display parser.
    @Test(arguments: [true, false])
    func touchOnThePrimaryDisplayIsTheIndigoScheduleAsBefore(_ duo: Bool) async throws {
        let data = duo ? Self.duo(unfolded: false) : SimulatorInputTests.displayJSON(current: "rot90", sensor: "landscapeRight")
        let sent = SimulatorInputTests.Sent()
        let receipt = try SimulatorInputTests.json(await Self.service(sent, data).run(["swipe", "0.2", "0.3", "0.6", "0.7", "0.4", "--simulator", Self.uuid]))
        let input = try #require(try simulatorInput(["swipe", "0.2", "0.3", "0.6", "0.7", "0.4", "--simulator", Self.uuid]))
        let expected = try DirectPhysicalTouch.plan(input.coreDeviceInput, display: DirectTouchDisplay(data))
        #expect(sent.reports.isEmpty && sent.touches.count == 1)
        #expect(sent.touches[0].map { [Double($0.nanoseconds), $0.x, $0.y, Double($0.phase)] }
            == expected.map { [Double($0.nanoseconds), $0.x, $0.y, Double($0.phase)] })
        #expect(receipt["route"] == nil && receipt["frameCount"] == nil && receipt["surfaceID"] == nil)
        #expect((receipt["screen"] as? [String: Any])?["display"] == nil)
    }

    @Test func multiTapUsesTheInterfaceDisplaysTouchscreen() async throws {
        for (data, display) in [(Self.duo(unfolded: true), Self.inner), (Self.duo(unfolded: false), Self.outer)] {
            let sent = SimulatorInputTests.Sent()
            _ = try await Self.service(sent, data).run(["multi-tap", "0.2", "0.2", "0.5", "0.5", "0.8", "0.8", "--simulator", Self.uuid])
            #expect(sent.reports.count == 1 && sent.reports[0].display == display)
        }
    }

    @Test func longScheduleIsThinnedToTheBridgeLimit() throws {
        let input = try #require(try simulatorInput(["long-press", "0.5", "0.5", "10", "--simulator", Self.uuid]))
        let samples = try DirectPhysicalTouch.plan(input.coreDeviceInput, display: DirectTouchDisplay(rotation: 90))
        #expect(samples.count > 512)
        let frames = try DirectSimulatorInput.reportFrames(samples)
        #expect(frames.times.count == 512 && frames.reports.count == 512)
        #expect(frames.times.first == 0 && frames.times.last == samples.last?.nanoseconds)
        #expect(zip(frames.times, frames.times.dropFirst()).allSatisfy { $0 < $1 })
        #expect(SimulatorInputTests.contacts(frames.reports[0][...]).count == 1 && SimulatorInputTests.contacts(frames.reports[511][...]).isEmpty)
        let tap = try DirectPhysicalTouch.plan(try #require(try simulatorInput(["tap", "0.5", "0.5", "--simulator", Self.uuid])).coreDeviceInput,
                                               display: DirectTouchDisplay(rotation: 0))
        #expect(try DirectSimulatorInput.reportFrames(tap).times == tap.map(\.nanoseconds))
    }

    // MARK: - Accessibility

    @Test func hitTestsNameTheInnerDisplayAndItsNativePoints() throws {
        let mapping = SimulatorHitMapping()
        mapping.update(try SimulatorDisplay(Self.duo(unfolded: true)), Self.duoInfo)
        #expect(mapping.displayId == 3)
        // Measured: the probe's Reset element at interface (475.5, 563) answered at (563, 475.5) on display 3.
        let point = mapping.native(475.5, 563)
        #expect(abs(point.0 - 563) < 0.001 && abs(point.1 - 475.5) < 0.001)
        mapping.update(try SimulatorDisplay(Self.duo(unfolded: false)), Self.duoInfo)
        #expect(mapping.displayId == 0 && mapping.native(100, 200) == (100, 200))
        func displayId(_ bytes: Data) throws -> Int? {
            let inspected = try JSONSerialization.jsonObject(with: KeyedArchiveInspector.inspect(bytes)) as? [String: Any]
            let fields = (inspected?["decoded"] as? [String: Any])?["fields"] as? [String: Any]
            return (fields?["parameters"] as? [String: Any])?["displayId"] as? Int
        }
        #expect(try displayId(AccessibilityRequest.hit(x: 1, y: 2)) == 0 && displayId(AccessibilityRequest.frontmost()) == 0)
        #expect(try displayId(AccessibilityRequest.hit(x: 1, y: 2, displayId: 3)) == 3)
        #expect(try displayId(AccessibilityRequest.frontmost(displayId: 3)) == 3)    }

    // MARK: - Captures and displays

    @Test func capturesDefaultToTheInterfaceDisplay() throws {
        let unfolded = try SimulatorDisplays.parse(Self.duo(unfolded: true))
        let chosen = try SimulatorDisplays.select(nil, in: unfolded)
        #expect(chosen.display.name == "LCD-1" && chosen.argument == "--display=3" && chosen.isInterface)
        let outer = try SimulatorDisplays.select("LCD", in: unfolded)
        #expect(outer.argument == "--display=1" && !outer.isInterface)
        let folded = try SimulatorDisplays.select(nil, in: SimulatorDisplays.parse(Self.duo(unfolded: false)))
        #expect(folded.display.name == "LCD" && folded.argument == "--display=1" && folded.isInterface)
        // Both awake (the earlier fixture, a fresh boot): the primary, as before.
        let both = try SimulatorDisplays.select(nil, in: SimulatorDisplays.parse(SimulatorDisplaysTests.duo))
        #expect(both.display.name == "LCD" && both.isInterface)
        #expect(try !SimulatorDisplays.select("LCD-1", in: SimulatorDisplays.parse(SimulatorDisplaysTests.duo)).isInterface)
        let television = try SimulatorDisplays.select(nil, in: SimulatorDisplays.parse(SimulatorDisplaysTests.television))
        #expect(television.argument == nil && television.isInterface)
    }

    @Test func screenTreeFollowsTheInterfaceDisplay() throws {
        let unfolded = try SimulatorDisplays.parse(Self.duo(unfolded: true))
        var screen = ScreenCommand(platform: "simulator", device: Self.uuid, mode: .tree)
        screen.selection = try SimulatorDisplays.select(nil, in: unfolded)
        #expect(screen.capturesPrimaryDisplay)
        screen.selection = try SimulatorDisplays.select("LCD", in: unfolded)
        #expect(!screen.capturesPrimaryDisplay)
    }

    @Test func displaysNamesTheInterfaceDisplay() throws {
        for (data, id) in [(Self.duo(unfolded: true), 3), (Self.duo(unfolded: false), 1)] {
            let request = SimulatorDisplayRequest.list(device: Self.uuid)
            let output = try request.execute(environment: SimulatorDisplaysTests.environment(data), run: { _ in
                Issue.record("displays ran a tool"); return Data()
            })
            let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
            #expect(root["interfaceDisplay"] as? Int == id && root["defaultCaptureDisplay"] as? Int == id)
        }
    }
}
