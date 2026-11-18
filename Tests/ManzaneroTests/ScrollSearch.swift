import Foundation
import MCP
import Testing
@testable import Manzanero

/// `scroll --search`: looking forward through a list that holds only the rows
/// near the screen, as the tvOS probe's list does.
struct ScrollSearchTests {
    typealias Value = AccessibilityArchiveValue

    /// A list of `count` rows, four on screen and one hidden just below.
    /// Scrolling the hidden row into view moves the list by one row.
    final class ListSession: AccessibilityExchange {
        let pid: Int32 = 43
        let count: Int
        var first = 1
        var scrolled: [UInt64] = []
        /// A container taller than the display, as the probe's list became.
        var withContainer = false
        var platform: AccessibilityPlatform { .simulator }

        init(count: Int) { self.count = count }

        static func token(_ id: UInt64, pid: Int32) -> Value { HostedProcessActionTests.Session.token(id, pid: pid) }
        static func rectangle(_ y: Int, height: Int = 60) -> Value {
            .object(className: "NSValue", fields: ["NS.rectval": .string("{{0, \(y)}, {300, \(height)}}")])
        }

        func start() throws {}
        func application(pid: Int32) throws -> AccessibilityRequest.Token { try AccessibilityResponse.token(Self.token(1, pid: pid)) }
        func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token { try AccessibilityResponse.token(Self.token(1, pid: pid)) }
        func snapshot(_ token: AccessibilityRequest.Token) throws -> Value {
            var rows: [Value] = []
            for offset in 0..<5 where first + offset <= count {
                let row = first + offset
                rows.append(HostedProcessActionTests.Session.record(UInt64(100 + row), pid: pid, attributes: [
                    "2001": .string("Row \(row)"), "5019": .string("row.\(row)"),
                    "2003": Self.rectangle(offset * 60), "2025": .boolean(offset < 4)]))
            }
            if withContainer {
                rows.append(HostedProcessActionTests.Session.record(50, pid: pid, attributes: [
                    "2003": Self.rectangle(-100, height: 3000), "2025": .boolean(false)]))
            }
            return HostedProcessActionTests.Session.record(1, pid: pid, children: rows)
        }
        func attributes(_ attributes: [Int], of token: AccessibilityRequest.Token) throws -> Value { .dictionary([:]) }
        func performAction(_ token: AccessibilityRequest.Token, action: AccessibilityRequest.Action, onSubmission: () -> Void) throws -> Bool {
            onSubmission()
            scrolled.append(token.objectID)
            // Only the hidden row below the screen moves the list.
            if token.objectID == UInt64(100 + first + 4), first + 4 < count { first += 1 }
            return true
        }
        func close() -> AccessibilitySession.Cleanup { .notSubscribed }
    }

    private func action(_ row: Int, search: Int) throws -> DirectAccessibilityAction {
        try DirectAccessibilityAction(CoreDeviceInput(device: "device", operation: "scroll-id",
                                                     operands: ["row.\(row)", DirectAccessibilityAction.searchOption, String(search)]))
    }

    private func search(_ row: Int, steps: Int, in session: ListSession) throws -> Int {
        let root = try session.application(pid: session.pid)
        return try action(row, search: steps).searchForward(maximum: steps, root: root, session: session, displayHeight: 240, onSubmission: {})
    }

    @Test func aRowAlreadyInTheTreeTakesNoStep() throws {
        let session = ListSession(count: 20)
        #expect(try search(3, steps: 10, in: session) == 0 && session.scrolled.isEmpty)
    }

    @Test func eachStepScrollsTheHiddenRowBelowUntilTheTargetAppears() throws {
        let session = ListSession(count: 20)
        // Rows 1...5 are in the tree; row 12 arrives after seven steps.
        #expect(try search(12, steps: 30, in: session) == 7)
        #expect(session.scrolled == [105, 106, 107, 108, 109, 110, 111])
    }

    @Test func aContainerTallerThanTheDisplayIsNeverScrolledTo() throws {
        let session = ListSession(count: 20)
        session.withContainer = true
        #expect(try search(9, steps: 30, in: session) == 4)
        #expect(!session.scrolled.contains(50))
    }

    @Test func itStopsAtTheStepLimitAndAtTheEndOfTheList() throws {
        let limited = ListSession(count: 20)
        let limit = #expect(throws: CommandFailure.self) { try search(15, steps: 3, in: limited) }
        #expect(limit?.code == .targetUnresolved && limit?.description.contains("after 3 search step(s)") == true)
        #expect(limit?.inputSent == .possible && limited.scrolled.count == 3)

        let ended = ListSession(count: 8)
        let end = #expect(throws: CommandFailure.self) { try search(30, steps: 50, in: ended) }
        #expect(end?.description.contains("stopped moving") == true)
        // Three steps reach the last rows; the steps after them change nothing.
        #expect(ended.first == 4 && ended.scrolled.count < 10)
    }

    @Test func searchIsParsedForScrollOnly() throws {
        #expect(try action(12, search: 30).search == 30)
        let plain = try DirectAccessibilityAction(CoreDeviceInput(device: "device", operation: "scroll-id", operands: ["row.1"]))
        #expect(plain.search == nil)
        for operands in [["row.1", "--search", "0"], ["row.1", "--search", "201"], ["row.1", "--search", "many"]] {
            #expect(throws: CommandFailure.self) {
                try DirectAccessibilityAction(CoreDeviceInput(device: "device", operation: "scroll-id", operands: operands))
            }
        }
        #expect(throws: CommandFailure.self) {
            try DirectAccessibilityAction(CoreDeviceInput(device: "device", operation: "press-id", operands: ["row.1", "--search", "5"]))
        }
        // With --index, the search follows it.
        let both = try DirectAccessibilityAction(CoreDeviceInput(device: "device", operation: "scroll-label",
                                                                operands: ["Row", "--index", "2", "--search", "9"]))
        #expect(both.index == 2 && both.search == 9 && both.text == "Row")
    }

    @Test func cliAndMCPCarryTheSearch() throws {
        let uuid = SimulatorDeviceTests.uuid
        let expected = CommandRequest.simulatorInput(try SimulatorInput(device: uuid, operation: "scroll-id", operands: ["row.9", "--search", "25"]))
        #expect(try request(["scroll", "--id", "row.9", "--search", "25", "--simulator", uuid]) == expected)
        let tool = try #require(MCPTools.definitions.first { $0.name == "scroll_to_element" })
        let args = try tool.command(["device": .string(uuid), "platform": "simulator", "by": "identifier", "text": "row.9", "search": 25])
        #expect(try request(args) == expected)
    }
}
