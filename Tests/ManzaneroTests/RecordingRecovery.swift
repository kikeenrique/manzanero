import Foundation
import Testing
@testable import Manzanero

/// The scenarios of docs/recording-recovery.md, on the recovery bookkeeping
/// the native recording loop consults. Times are nanoseconds from an origin.
struct RecordingRecoveryTests {
    let second: UInt64 = 1_000_000_000

    func started(duration: UInt64 = 60) -> RecordingRecovery {
        var recovery = RecordingRecovery(durationNanoseconds: duration * second)
        recovery.packet(at: 1 * second)
        recovery.picture(at: 1 * second)
        return recovery
    }

    @Test func nothingIsRecoveredBeforeTheFirstPicture() {
        var recovery = RecordingRecovery(durationNanoseconds: 60 * second)
        #expect(recovery.stall(at: 20 * second) == nil)
        #expect(recovery.decide(.streamEnded, at: 2 * second) == .fail)
        #expect(recovery.restarts == 0 && recovery.gaps.isEmpty)
    }

    @Test func aStreamThatEndsAndComesBackLeavesOneGap() {
        var recovery = started()
        for t in stride(from: 1 * second, through: 21 * second, by: Int(second / 10)) { recovery.packet(at: t); recovery.picture(at: t) }
        #expect(recovery.decide(.streamEnded, at: 22 * second) == .restart)
        // The first picture of the new session closes the gap, which starts at the last picture.
        recovery.picture(at: 24 * second + second / 2)
        #expect(recovery.restarts == 1)
        #expect(recovery.gaps == [RecordingRecovery.Gap(atSeconds: 20, seconds: 3.5, reason: .streamEnded)])
        #expect(recovery.json["lastPictureHeldFrom"] is NSNull)
    }

    @Test func undecodablePacketsAreAStallAfterThreeSecondsAndSilenceIsNot() {
        // A still screen's packet rate is not measured: silence is left to the liveness check.
        let quiet = started()
        #expect(quiet.stall(at: 4 * second) == nil && quiet.stall(at: 30 * second) == nil)
        var garbled = started()
        for t in stride(from: 1 * second, through: 5 * second, by: Int(second / 10)) { garbled.packet(at: t) }
        #expect(garbled.stall(at: 3 * second) == nil)
        #expect(garbled.stall(at: 5 * second) == .noPictures)
        // One packet after the pictures stop, as a still Apple TV screen
        // sends, is not a stream failing to decode.
        var still = started()
        still.packet(at: 2 * second)
        #expect(still.stall(at: 4 * second + second / 2) == nil && still.stall(at: 30 * second) == nil)
    }

    @Test func threeRestartsThenAFailureIsThrownAsBefore() {
        var recovery = started()
        #expect(recovery.decide(.transportFailed, at: 5 * second) == .restart)
        // A restart that delivers nothing within its budget is a stall, and a restart of its own.
        #expect(recovery.stall(at: 10 * second) == nil)
        #expect(recovery.stall(at: 15 * second) == .noPictures)
        #expect(recovery.decide(.noPictures, at: 15 * second) == .restart)
        #expect(recovery.decide(.transportFailed, at: 16 * second) == .restart)
        #expect(recovery.decide(.transportFailed, at: 17 * second) == .fail)
        // One loss, however many attempts it took: one gap.
        #expect(recovery.restarts == 3 && recovery.gaps.count == 1)
    }

    @Test func aStallWithNoRestartLeftHoldsTheLastPicture() {
        var recovery = started()
        for loss in [UInt64(3), 5, 7] {
            #expect(recovery.decide(.streamEnded, at: loss * second) == .restart)
            recovery.picture(at: (loss + 1) * second)
        }
        #expect(recovery.gaps.count == 3)
        #expect(recovery.decide(.noPackets, at: 12 * second) == .hold)
        #expect(recovery.heldFrom == 7)
        // Held: no more stalls are reported.
        #expect(recovery.stall(at: 30 * second) == nil)
    }

    @Test func noRestartBeginsWithLessThanTwoSecondsLeft() {
        var recovery = started(duration: 10)
        recovery.picture(at: 9 * second)
        #expect(recovery.decide(.streamEnded, at: 9 * second + second / 2) == .fail)
        #expect(recovery.decide(.noPackets, at: 9 * second + second / 2) == .hold)
        #expect(recovery.restarts == 0)
    }
}
