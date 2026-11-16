import Foundation
import Testing
@testable import Manzanero

struct SimulatorDeviceTests {
    static let uuid = "11111111-2222-3333-4444-555555555555"

    static func info(_ state: String = "Booted", width: Double = 390, height: Double = 844, scale: Double = 3) -> SimulatorDeviceInfo {
        SimulatorDeviceInfo(uuid: uuid, name: "Fixture", state: state, widthPoints: width, heightPoints: height, scale: scale)
    }

    @Test func bootedSimulatorIsReturnedWithItsGeometry() throws {
        var looked: [String] = []
        let info = try SimulatorDevice.requireBooted(Self.uuid, operation: "tap", lookup: { looked.append($0); return Self.info() })
        #expect(looked == [Self.uuid])
        #expect(info.booted && info.widthPoints == 390 && info.heightPoints == 844 && info.scale == 3)
        #expect(info.screenJSON["orientation"] as? String == "not-read")
    }

    // MARK: - Display information

    @Test(arguments: [("rot0", "rot0", 0), ("rot0", "rot90", 90), ("rot0", "rot180", 180), ("rot0", "rot270", 270), ("rot90", "rot270", 0)])
    func displayRotationIsNativePlusCurrent(_ native: String, _ current: String, _ rotation: Int) throws {
        let display = try SimulatorDisplay(SimulatorInputTests.displayJSON(current: current, native: native))
        #expect(display.rotation == rotation && display.displayUUID == SimulatorInputTests.primaryDisplay && display.backlight == "activeOn" && display.isPrimary)
        let ax = display.accessibility(Self.info())
        let turned = rotation == 90 || rotation == 270
        #expect(ax.bounds.width == (turned ? 844 : 390) && ax.bounds.height == (turned ? 390 : 844))
        #expect(ax.orientation == "rot\(rotation)" && ax.displayId == 0 && ax.pointScale == 3)
        #expect(display.screenJSON(Self.info())["interfaceWidthPoints"] as? Double == ax.bounds.width)
    }

    @Test func displayInformationMustNameOnePrimaryDisplay() throws {
        for data in [SimulatorInputTests.displayJSON(uniqueId: nil), SimulatorInputTests.displayJSON(current: "sideways"),
                     Data("{\"info\":{\"outcome\":\"failure\"}}".utf8), Data("[]".utf8)] {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorDisplay(data) }
            #expect(failure.code == .transportFailed && failure.inputSent == .none)
        }
        // Accessibility does not need an awake display; touch does.
        let dark = try SimulatorDisplay(SimulatorInputTests.displayJSON(backlight: "off"))
        #expect(dark.accessibility(Self.info()).bounds.width == 390)
        let failure = try #require(throws: CommandFailure.self) { try dark.touch() }
        #expect(failure.code == .displayOff && failure.description.contains("button home"))
    }

    /// Hit tests: interface points in, native portrait points out (measured
    /// in landscape on an iPhone 17e and an iPad mini simulator).
    @Test(arguments: [("rot0", 100.0, 200.0, 100.0, 200.0), ("rot270", 421.0, 284.0, 106.0, 421.0),
                      ("rot90", 421.0, 284.0, 284.0, 423.0), ("rot180", 100.0, 200.0, 290.0, 644.0)])
    func hitPointsAreMappedToNativePoints(_ current: String, _ x: Double, _ y: Double, _ nativeX: Double, _ nativeY: Double) throws {
        let mapping = SimulatorHitMapping()
        mapping.update(try SimulatorDisplay(SimulatorInputTests.displayJSON(current: current)), Self.info())
        let point = mapping.native(x, y)
        #expect(abs(point.0 - nativeX) < 1e-9 && abs(point.1 - nativeY) < 1e-9)
    }

    @Test(arguments: ["Shutdown", "Booting", "Shutting Down", ""])
    func unbootedSimulatorIsRefusedBeforeAnyConnection(state: String) throws {
        let failure = try #require(throws: CommandFailure.self) {
            try SimulatorDevice.requireBooted(Self.uuid, operation: "tap", lookup: { _ in Self.info(state) })
        }
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none)
        #expect(failure.description.contains("not Booted") && failure.description.contains("boot --simulator \(Self.uuid)"))
        #expect(failure.retry == .afterAction)
    }

    @Test func lookupFailuresKeepTheirClassification() throws {
        let missing = CommandFailure(.targetUnresolved, "No simulator with this UUID exists in the default device set.", inputSent: .none)
        let failure = try #require(throws: CommandFailure.self) {
            try SimulatorDevice.requireBooted(Self.uuid, operation: "tree", lookup: { _ in throw missing })
        }
        #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
    }

    @Test(arguments: ["booted", "iPhone 17e", "", "1111"])
    func simulatorOperationsRequireAUUID(device: String) throws {
        let failure = try #require(throws: CommandFailure.self) { try SimulatorDevice.requireUUID(device, operation: "tap") }
        #expect(failure.code == .usage && failure.description.contains("UUID"))
        #expect(try SimulatorDevice.requireUUID(Self.uuid.lowercased(), operation: "tap") == Self.uuid)
    }

    @Test func developerDirectoryPrefersTheEnvironmentThenXcodeSelect() throws {
        var calls: [[String]] = []
        let fromEnvironment = try SimulatorDevice.developerDirectory(environment: ["DEVELOPER_DIR": "/Xcode.app/Contents/Developer"],
                                                                     run: { arguments, _ in calls.append(arguments); return Data() })
        #expect(fromEnvironment == "/Xcode.app/Contents/Developer" && calls.isEmpty)
        let selected = try SimulatorDevice.developerDirectory(environment: [:], run: { arguments, executable in
            calls.append([executable] + arguments); return Data("/Selected/Developer\n".utf8)
        })
        #expect(selected == "/Selected/Developer" && calls == [["/usr/bin/xcode-select", "-p"]])
        #expect(throws: CommandFailure.self) {
            try SimulatorDevice.developerDirectory(environment: [:], run: { _, _ in Data("error".utf8) })
        }
    }
}
