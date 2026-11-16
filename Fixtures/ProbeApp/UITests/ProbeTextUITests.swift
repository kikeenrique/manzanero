import XCTest

/// The text probe (probe.text.*): the field and its readout exist, start empty,
/// and a tap focuses the field without an on-screen keyboard covering it.
final class ProbeTextUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    private func value() throws -> [String: Any] {
        let element = app.descendants(matching: .any)["probe.text.value"]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "probe.text.value is missing")
        let text = try XCTUnwrap(element.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor
    func testFieldStartsEmptyAndFocusesWithoutAKeyboard() throws {
        let field = app.textFields["probe.text.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.label, "Probe text field")
        let initial = try value()
        XCTAssertEqual(initial["v"] as? Int, 1)
        XCTAssertEqual(initial["text"] as? String, "")
        XCTAssertEqual(initial["utf8"] as? Int, 0)
        XCTAssertEqual(initial["focused"] as? Bool, false)
        // Below the touch plan's region (y <= 0.65 of the screen) and inside the window.
        XCTAssertGreaterThan(field.frame.minY, app.frame.height * 0.65)
        XCTAssertTrue(app.frame.contains(field.frame))

        field.tap()
        let deadline = Date().addingTimeInterval(5)
        var focused = try value()
        while focused["focused"] as? Bool != true, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            focused = try value()
        }
        XCTAssertEqual(focused["focused"] as? Bool, true)
        XCTAssertFalse(app.keyboards.element.exists, "the field has an empty input view")
        XCTAssertTrue(field.isHittable)
    }
}
