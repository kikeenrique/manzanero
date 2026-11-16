import Foundation
import Testing
@testable import Manzanero

struct PhysicalInputOperandsTests {
    /// `args` is the internal operation followed by its operands.
    func native(_ args: [String]) throws -> CoreDeviceInput {
        try CoreDeviceInput.validated(device: "fixture", operation: args[0], operands: Array(args.dropFirst()))
    }

    @Test func acceptsCoordinatedPathsAndHorizontalPinch() throws {
        try PhysicalInputOperands.validate("pinch", ["0.5", "0.5", "0.5", "1", "0.5"])
        try PhysicalInputOperands.validate("multi-drag", ["0.03", "0", "0", "1", "1", "1", "1", "0", "0"])
        #expect(try native(["pinch", "0.5", "0.5", "0.5", "1", "0.5"]).operation == "pinch")
        #expect(try native(["multi-drag", "0.03", "0", "0", "1", "1", "1", "1", "0", "0"]).operation == "multi-drag")
    }

    @Test(arguments: [
        ["pinch", "0", "0.5", "0.5", "1", "1"],
        ["pinch", "0.5", "1.1", "0.5", "1", "1"],
        ["pinch", "0.5", "0.5", "0", "1", "1"],
        ["pinch", "0.5", "0.5", "0.5", "0.5", "1"],
        ["pinch", "nan", "0.5", "0.5", "1", "1"],
        ["pinch", "0.5", "0.5", "0.00000001", "0.00000002", "1"],
        ["pinch", "0.5", "0.5", "0.5", "1", "11"],
        ["multi-drag", "1", "0", "0", "1", "1"],
        ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "0", "0"],
        ["multi-drag", "0", "0", "0", "1", "1", "1", "1", "0", "0"],
        ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "inf"]
    ]) func rejectsInvalidCoordinatedGestures(_ operands: [String]) {
        #expect(throws: CommandFailure.self) { try native(operands) }
    }

    @Test func acceptsFivePathsAndRejectsSix() throws {
        let path = ["0", "0", "1", "1"]
        let five = Array(repeating: path, count: 5).flatMap { $0 }
        #expect(try native(["multi-drag", "10"] + five).operands.count == 21)
        #expect(throws: CommandFailure.self) { try native(["multi-drag", "10"] + five + path) }
    }

    @Test func physicalTypingPreservesLiteralText() throws {
        let text = "--literal 'text'; $(touch sentinel)\tOK\n"
        #expect(try native(["type", text]).operands == [text, "us"])
        #expect(try native(["type", text, "Spanish - ISO"]).operands == [text, "spanish-iso"])
    }

    @Test(arguments: ["", "🙂", "\0", "\r", "\r\n", "\u{1b}", "→", String(repeating: "a", count: 513), String(repeating: "é", count: 512)])
    func rejectsUnsupportedPhysicalTextBeforeDispatch(_ text: String) {
        #expect(throws: CommandFailure.self) { try native(["type", text]) }
    }

    @Test func acceptsNormalizedCoordinateBoundaries() throws {
        #expect(try native(["multi-tap", "0", "1", "0.5", "0.5"]).operands == ["0", "1", "0.5", "0.5"])
        #expect(try native(["swipe", "0", "0.9", "0", "0.1", "0.5"]).operation == "swipe")
    }

    @Test(arguments: [
        ["tap", "nan", "0"], ["tap", "1.1", "0"], ["tap", "-0.1", "0"],
        ["tap", "0"], ["multi-tap", "0", "0", "1"],
        ["drag", "0", "0", "1", "1", "inf"], ["drag", "0", "0", "1", "1", "0"],
        ["button", "--help"], ["key", "unknown"]
    ]) func rejectsInvalidInput(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try native(args) }
    }

    @Test func validatorRefusesOperationsItDoesNotOwn() {
        for operation in ["type", "tree", "long-press", "hid-info"] {
            #expect(throws: CommandFailure.self) { try PhysicalInputOperands.validate(operation, []) }
        }
    }
}
