import XCTest

/// End-to-end checks of the recording path in the iOS Simulator. XCUITest
/// synthesizes the touches here; this exercises UIKit delivery to the probe and
/// the accessibility readback, not Manzanero's physical-device input path.
final class ProbeAppUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    private func readout(_ identifier: String) throws -> [String: Any] {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) is missing")
        let value = try XCTUnwrap(element.value as? String, "\(identifier) has no string value")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    @MainActor
    private func waitForSummary(_ condition: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        var summary = try readout("probe.touch.summary")
        while !condition(summary), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            summary = try readout("probe.touch.summary")
        }
        return summary
    }

    @MainActor
    func testLaunchShowsEmptySessionAndResetElement() throws {
        let summary = try readout("probe.touch.summary")
        XCTAssertEqual(summary["v"] as? Int, 1)
        XCTAssertEqual(summary["events"] as? Int, 0)
        XCTAssertEqual(summary["maxActive"] as? Int, 0)
        let session = try XCTUnwrap(summary["session"] as? String)
        XCTAssertEqual(session.count, 16)
        let gesture = try readout("probe.touch.last-gesture")
        XCTAssertEqual(gesture["gesture"] as? Int, 0)
        XCTAssertEqual(gesture["session"] as? String, session)

        let reset = app.descendants(matching: .any)["probe.touch.reset"]
        XCTAssertTrue(reset.exists)
        XCTAssertEqual(reset.label, "Reset probe")
        XCTAssertEqual(reset.value as? String, session)
        XCTAssertTrue(reset.frame.width > 0 && reset.frame.height > 0)
        XCTAssertTrue(app.frame.contains(reset.frame))

        // Relaunching must start a new session.
        app.terminate()
        app.launch()
        let relaunched = try readout("probe.touch.summary")
        XCTAssertNotEqual(relaunched["session"] as? String, session)
    }

    @MainActor
    func testTapIsRecordedAtItsNormalizedPosition() throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        let summary = try waitForSummary { ($0["ended"] as? Int ?? 0) >= 1 }
        XCTAssertEqual(summary["began"] as? Int, 1)
        XCTAssertEqual(summary["ended"] as? Int, 1)
        XCTAssertEqual(summary["cancelled"] as? Int, 0)
        XCTAssertEqual(summary["maxActive"] as? Int, 1)
        XCTAssertEqual(summary["gestures"] as? Int, 1)

        let gesture = try readout("probe.touch.last-gesture")
        let contacts = try XCTUnwrap(gesture["contacts"] as? [[String: Any]])
        XCTAssertEqual(contacts.count, 1)
        let from = try XCTUnwrap(contacts[0]["from"] as? [Double])
        XCTAssertEqual(from[0], 0.3, accuracy: 0.02)
        XCTAssertEqual(from[1], 0.6, accuracy: 0.02)
        XCTAssertEqual(contacts[0]["end"] as? String, "ended")
    }

    @MainActor
    func testRecentGesturesListsBothOfTwoTaps() throws {
        let empty = try readout("probe.touch.recent-gestures")
        XCTAssertEqual(empty["v"] as? Int, 1)
        XCTAssertEqual(empty["gestures"] as? Int, 0)
        XCTAssertEqual((empty["recent"] as? [Any])?.count, 0)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        _ = try waitForSummary { ($0["gestures"] as? Int ?? 0) >= 1 && ($0["active"] as? Int) == 0 }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).tap()
        let summary = try waitForSummary { ($0["gestures"] as? Int ?? 0) >= 2 && ($0["active"] as? Int) == 0 }
        XCTAssertEqual(summary["gestures"] as? Int, 2)

        let recent = try readout("probe.touch.recent-gestures")
        XCTAssertEqual(recent["session"] as? String, summary["session"] as? String)
        XCTAssertEqual(recent["gestures"] as? Int, 2)
        XCTAssertEqual(recent["dropped"] as? Int, 0)
        let entries = try XCTUnwrap(recent["recent"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["gesture"] as? Int }, [1, 2])
        let starts = try entries.map { entry -> [Double] in
            let contacts = try XCTUnwrap(entry["contacts"] as? [[String: Any]])
            XCTAssertEqual(contacts.count, 1)
            XCTAssertEqual(contacts.first?["end"] as? String, "ended")
            return try XCTUnwrap(contacts.first?["from"] as? [Double])
        }
        XCTAssertEqual(starts[0][0], 0.3, accuracy: 0.02)
        XCTAssertEqual(starts[0][1], 0.5, accuracy: 0.02)
        XCTAssertEqual(starts[1][0], 0.7, accuracy: 0.02)
        XCTAssertEqual(starts[1][1], 0.6, accuracy: 0.02)

        // The newest entry is the last-gesture readout.
        let last = try readout("probe.touch.last-gesture")
        XCTAssertEqual(last["gesture"] as? Int, 2)
        let lastContacts = try XCTUnwrap(last["contacts"] as? [[String: Any]])
        XCTAssertEqual(lastContacts.first?["from"] as? [Double], starts[1])
    }

    @MainActor
    func testHoldDurationIsMeasured() throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.5)
        _ = try waitForSummary { ($0["gestures"] as? Int ?? 0) >= 1 }
        let gesture = try readout("probe.touch.last-gesture")
        let contacts = try XCTUnwrap(gesture["contacts"] as? [[String: Any]])
        let duration = try XCTUnwrap(contacts.first?["duration"] as? Double)
        // XCUITest's own timing is approximate; this checks the measurement path, not precision.
        XCTAssertEqual(duration, 1.5, accuracy: 0.4)
    }

    @MainActor
    func testTwoFingerTapReportsTwoSimultaneousContacts() throws {
        app.twoFingerTap()
        let summary = try waitForSummary { ($0["gestures"] as? Int ?? 0) >= 1 && ($0["active"] as? Int) == 0 }
        XCTAssertEqual(summary["maxActive"] as? Int, 2)
        XCTAssertEqual(summary["began"] as? Int, 2)
        let gesture = try readout("probe.touch.last-gesture")
        let contacts = try XCTUnwrap(gesture["contacts"] as? [[String: Any]])
        XCTAssertEqual(contacts.compactMap { $0["c"] as? Int }, [0, 1])
    }
}
