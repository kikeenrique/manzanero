import Foundation
import Testing
@testable import ProbeAnalysis

@Suite struct PlanTests {
    @Test func builtInPlanIsValidAndClearOfEdges() {
        let validation = TouchPlan.builtIn.validate()
        #expect(validation.errors.isEmpty)
        #expect(validation.warnings.isEmpty)
        let points = TouchPlan.builtIn.actions.flatMap(\.action.allPoints)
        #expect(points.allSatisfy { (0.25...0.75).contains($0.x) && (0.3...0.65).contains($0.y) })
        let maxContacts = TouchPlan.builtIn.actions.map { $0.action.expectedGestures.map(\.maxActive).max() ?? 0 }
        #expect(Set(maxContacts) == [1, 2, 3, 4, 5])
    }

    @Test func planFileRoundTripsEveryKind() throws {
        let json = """
        {"v":1,"name":"custom","settleSeconds":0.25,"positionTolerance":0.02,"actions":[
          {"id":"t","kind":"tap","x":0.5,"y":0.4},
          {"id":"l","kind":"long-press","x":0.5,"y":0.5,"seconds":1.2},
          {"id":"s","kind":"swipe","from":[0.5,0.7],"to":[0.5,0.3],"seconds":0.4},
          {"id":"d","kind":"drag","from":[0.3,0.5],"to":[0.7,0.5],"seconds":0.6},
          {"id":"m","kind":"multi-tap","points":[[0.3,0.4],[0.7,0.4]]},
          {"id":"md","kind":"multi-drag","seconds":0.5,"paths":[[0.3,0.6,0.3,0.4],[0.7,0.6,0.7,0.4]]},
          {"id":"p","kind":"pinch","center":[0.5,0.5],"startSpan":0.4,"endSpan":0.2,"seconds":0.5},
          {"id":"g","kind":"gesture","frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.5}]},{"ms":100,"touches":[]}]}
        ]}
        """
        let plan = try TouchPlan.decode(Data(json.utf8))
        #expect(plan.validate().isValid)
        #expect(plan.settle == 0.25)
        #expect(plan.tolerances == Tolerances(position: 0.02, duration: TouchPlan.defaultDurationTolerance))
        #expect(plan.actions.map(\.action.kind) == ["tap", "long-press", "swipe", "drag", "multi-tap", "multi-drag", "pinch", "gesture"])
        let again = try TouchPlan.decode(JSONEncoder().encode(plan))
        #expect(again == plan)
    }

    @Test func unknownKindIsRejected() {
        #expect(throws: DecodingError.self) {
            try TouchPlan.decode(Data(#"{"v":1,"name":"x","actions":[{"id":"a","kind":"rotate","x":0.5,"y":0.5}]}"#.utf8))
        }
    }

    @Test func commandArgumentsMatchManzaneroSyntax() {
        #expect(TouchAction.tap(NormalizedPoint(0.5, 0.45)).cliArguments == ["tap", "0.5", "0.45"])
        #expect(TouchAction.longPress(NormalizedPoint(0.1, 1), seconds: 0.8).cliArguments == ["long-press", "0.1", "1", "0.8"])
        #expect(TouchAction.swipe(from: NormalizedPoint(0.5, 0.65), to: NormalizedPoint(0.5, 0.35), seconds: 0.5).cliArguments
                == ["swipe", "0.5", "0.65", "0.5", "0.35", "0.5"])
        #expect(TouchAction.multiDrag(seconds: 0.6, paths: [TouchPath(from: NormalizedPoint(0.3, 0.6), to: NormalizedPoint(0.3, 0.4)),
                                                           TouchPath(from: NormalizedPoint(0.7, 0.6), to: NormalizedPoint(0.7, 0.4))]).cliArguments
                == ["multi-drag", "0.6", "0.3", "0.6", "0.3", "0.4", "0.7", "0.6", "0.7", "0.4"])
        #expect(TouchAction.pinch(center: NormalizedPoint(0.5, 0.5), startSpan: 0.2, endSpan: 0.5, seconds: 0.6).cliArguments
                == ["pinch", "0.5", "0.5", "0.2", "0.5", "0.6"])
        let gesture = TouchAction.sequence([SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.4)]),
                                            SequenceFrame(ms: 60, touches: [])])
        #expect(gesture.cliArguments == ["gesture", #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]}]}"#])
        #expect(formatCLINumber(1.0 / 3) == "0.333333")
        #expect(formatCLINumber(0) == "0")
    }

    @Test func validationMirrorsManzaneroLimits() {
        func errors(_ action: TouchAction) -> [String] { action.validationErrors() }
        #expect(!errors(.tap(NormalizedPoint(1.2, 0.5))).isEmpty)
        #expect(!errors(.tap(NormalizedPoint(.nan, 0.5))).isEmpty)
        #expect(!errors(.longPress(NormalizedPoint(0.5, 0.5), seconds: 0.05)).isEmpty)
        #expect(!errors(.swipe(from: NormalizedPoint(0.5, 0.5), to: NormalizedPoint(0.5, 0.2), seconds: 11)).isEmpty)
        #expect(!errors(.multiTap([NormalizedPoint(0.5, 0.5)])).isEmpty)
        #expect(!errors(.multiTap([NormalizedPoint(0.5, 0.5), NormalizedPoint(0.5, 0.5)])).isEmpty)
        #expect(!errors(.multiTap(Array(repeating: NormalizedPoint(0.5, 0.5), count: 6))).isEmpty)
        #expect(!errors(.pinch(center: NormalizedPoint(0.5, 0.5), startSpan: 0.3, endSpan: 0.3, seconds: 0.5)).isEmpty)
        #expect(!errors(.pinch(center: NormalizedPoint(0.9, 0.5), startSpan: 0.1, endSpan: 0.5, seconds: 0.5)).isEmpty)
        // Gesture rules: first at 0 with a touch, strictly increasing, ends empty, ids contiguous 0...4.
        #expect(!errors(.sequence([SequenceFrame(ms: 0, touches: [SequenceTouch(id: 1, x: 0.5, y: 0.5)]),
                                   SequenceFrame(ms: 10, touches: [])])).isEmpty)
        #expect(!errors(.sequence([SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.5)]),
                                   SequenceFrame(ms: 0, touches: [])])).isEmpty)
        #expect(!errors(.sequence([SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.5)]),
                                   SequenceFrame(ms: 10, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.5)])])).isEmpty)
        #expect(errors(.sequence([SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.5)]),
                                  SequenceFrame(ms: 10, touches: [])])).isEmpty)

        var plan = TouchPlan(name: "bad", actions: [PlannedAction(id: "same", action: .tap(NormalizedPoint(0.5, 0.5))),
                                                    PlannedAction(id: "same", action: .tap(NormalizedPoint(0.02, 0.5)))])
        var validation = plan.validate()
        #expect(validation.errors.contains { $0.contains("duplicate id") })
        #expect(validation.warnings.contains { $0.contains("edge") })
        plan = TouchPlan(name: "reset-box", actions: [PlannedAction(id: "r", action: .tap(NormalizedPoint(0.5, 0.87)))])
        validation = plan.validate()
        #expect(validation.isValid)
        #expect(validation.warnings.contains { $0.contains("reset box") })
        #expect(TouchPlan(name: "empty", actions: []).validate().errors == ["plan has no actions"])
    }

    @Test func expectedGesturesFollowManzaneroSchedules() throws {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5)).expectedGestures
        #expect(tap.count == 1)
        #expect(tap[0].contacts[0].holdSeconds == 0.08)
        #expect(!tap[0].contacts[0].moves)

        let swipe = TouchAction.swipe(from: NormalizedPoint(0.5, 0.7), to: NormalizedPoint(0.5, 0.3), seconds: 0.5).expectedGestures
        #expect(abs(swipe[0].contacts[0].holdSeconds - 0.501) < 1e-9)
        #expect(swipe[0].contacts[0].moves)

        let pinch = TouchAction.pinch(center: NormalizedPoint(0.5, 0.5), startSpan: 0.2, endSpan: 0.6, seconds: 0.5).expectedGestures
        #expect(pinch[0].maxActive == 2)
        #expect(abs(pinch[0].contacts[0].start.x - 0.4) < 1e-9)
        #expect(abs(pinch[0].contacts[1].end.x - 0.8) < 1e-9)

        // A double tap is two gestures; the staggered pair is one gesture with two contacts of different holds.
        let double = try #require(TouchPlan.builtIn.actions.first { $0.id == "sequence-double-tap" }).action.expectedGestures
        #expect(double.count == 2)
        #expect(double.map { $0.contacts[0].startOffset } == [0, 0.26])
        #expect(double.allSatisfy { abs($0.contacts[0].holdSeconds - 0.06) < 1e-9 })
        let staggered = try #require(TouchPlan.builtIn.actions.first { $0.id == "sequence-staggered-2" }).action.expectedGestures
        #expect(staggered.count == 1)
        #expect(staggered[0].maxActive == 2)
        #expect(staggered[0].contacts.map(\.startOffset) == [0, 0.15])
        #expect(staggered[0].contacts.map(\.holdSeconds) == [0.45, 0.45])

        // A released id reused at a new position is a new contact.
        let reused = TouchAction.sequence([
            SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.3, y: 0.5), SequenceTouch(id: 1, x: 0.7, y: 0.5)]),
            SequenceFrame(ms: 100, touches: [SequenceTouch(id: 1, x: 0.7, y: 0.5)]),
            SequenceFrame(ms: 200, touches: [SequenceTouch(id: 0, x: 0.4, y: 0.6), SequenceTouch(id: 1, x: 0.7, y: 0.4)]),
            SequenceFrame(ms: 300, touches: []),
        ]).expectedGestures
        #expect(reused.count == 1)
        #expect(reused[0].contacts.count == 3)
        #expect(reused[0].contacts.filter(\.moves).count == 1)
    }
}
