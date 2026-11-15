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
        #expect(info.screenJSON["orientation"] as? String == "portrait-assumed")
    }

    @Test(arguments: ["Shutdown", "Booting", "Shutting Down", ""])
    func unbootedSimulatorIsRefusedBeforeAnyConnection(state: String) throws {
        let failure = try #require(throws: CommandFailure.self) {
            try SimulatorDevice.requireBooted(Self.uuid, operation: "tap", lookup: { _ in Self.info(state) })
        }
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none)
        #expect(failure.description.contains("not Booted") && failure.description.contains("simulator \(Self.uuid) boot"))
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
