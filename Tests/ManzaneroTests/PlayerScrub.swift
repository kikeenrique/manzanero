import Foundation
import MCP
import Testing
@testable import Manzanero

/// `scrub`: the loop against a fake of Apple's player as it was measured.
struct PlayerScrubTests {
    /// Playing or paused, controls shown or not, a preview that only a
    /// paused swipe moves (further when quicker), and select to commit.
    final class Player: @unchecked Sendable {
        var position: Int
        var preview: Int
        let length: Int
        var playing: Bool
        var shown: Bool
        /// Seconds of preview a full-travel swipe moves, by its duration;
        /// a duration missing here moves nothing (an ignored quick swipe).
        var secondsPerFullSwipe: [Double: Double] = [0.6: 30, 0.3: 55, 0.2: 71, 0.1: 132]
        var pressed: [String] = []
        var reads = 0
        /// When set, 0.1 s swipes move by these seconds in turn, whatever
        /// their travel: the Apple TV 4K's 27, 209 and 0.
        var erraticQuickShifts: [Int]?
        private var quickIndex = 0

        init(at position: Int, length: Int = 600, playing: Bool, shown: Bool) {
            self.position = position; preview = position; self.length = length; self.playing = playing; self.shown = shown
        }

        func read() -> PlayerPosition {
            reads += 1
            // A playing video advances between readings.
            if playing { position += 2; preview = position }
            return shown ? PlayerPosition(elapsed: preview, remaining: length - preview, marker: preview) : PlayerPosition()
        }

        func press(_ words: [String]) {
            pressed.append(words.joined(separator: " "))
            switch words[0] {
            case "play-pause":
                playing.toggle()
                shown = true
            case "select":
                position = preview
                playing = true
            case let swipe where swipe.hasPrefix("swipe-"):
                guard !playing, let travel = Double(words[2]), let seconds = Double(words[4]),
                      let full = secondsPerFullSwipe[seconds] else { return }
                var shift = Int((full * travel / 0.9).rounded())
                if seconds == 0.1, let erratic = erraticQuickShifts {
                    shift = erratic[quickIndex % erratic.count]
                    quickIndex += 1
                }
                preview = min(max(preview + (swipe == "swipe-right" ? shift : -shift), 0), length)
            default: break
            }
        }
    }

    static let simulator = Target(platform: .simulator, identifier: "AAAAAAAA-0000-4000-8000-0000000000A1")

    static func scrub(_ player: Player, to text: String, tolerance: String? = nil,
                      isolation: isolated (any Actor)? = #isolation) async throws -> [String: Any] {
        try await PlayerScrub.run(ScrubCommand(simulator, to: text, tolerance: tolerance), read: { player.read() },
                                  press: { player.press($0) }, wait: { _ in })
    }

    @Test func timesAreReadAsThePlayerWritesThem() throws {
        #expect(ScrubCommand.clock("00:18") == 18 && ScrubCommand.clock("-21:33") == 1293 && ScrubCommand.clock("1:02:03") == 3723)
        #expect(ScrubCommand.clock("1:75") == nil && ScrubCommand.clock("abc") == nil && ScrubCommand.clock("12") == nil)
        #expect(try ScrubCommand.parseGoal("95") == .seconds(95) && ScrubCommand.parseGoal("1:35") == .seconds(95))
        #expect(try ScrubCommand.parseGoal("40%") == .fraction(0.4))
        for bad in ["-5", "140%", "soon", ""] { #expect(throws: CommandFailure.self) { try ScrubCommand.parseGoal(bad) } }
        let tree = try JSONSerialization.data(withJSONObject: ["nodes": [
            ["identifier": "AXElapsedTime", "label": "00:42"], ["identifier": "AXRemainingTime", "label": "-09:18"],
            ["identifier": "Elapsed Time Scrubbing Marker", "label": "01:10"], ["identifier": "Media Controls", "value": "42 seconds elapsed"]]])
        #expect(PlayerPosition(tree: tree) == PlayerPosition(elapsed: 42, remaining: 558, marker: 70))
        #expect(PlayerPosition(tree: tree).preview == 70 && PlayerPosition(tree: tree).length == 600)
    }

    @Test func aPlayingVideoWithHiddenControlsIsPausedThenScrubbedAndCommitted() async throws {
        let player = Player(at: 40, playing: true, shown: false)
        let result = try await Self.scrub(player, to: "9:00")
        #expect(result["status"] as? String == "reached" && result["pausedByCommand"] as? Bool == true)
        #expect(player.pressed.first == "play-pause" && player.pressed.last == "select")
        #expect(abs(player.position - 540) <= 10 && player.playing)
        // It went quicker for the long way.
        #expect(player.pressed.contains { $0.hasSuffix("--seconds 0.1") })
    }

    /// Controls on screen while it plays: the second reading shows the time
    /// moving, so the command pauses before swiping.
    @Test func shownControlsOnAPlayingVideoStillPauseFirst() async throws {
        let player = Player(at: 100, playing: true, shown: true)
        let result = try await Self.scrub(player, to: "2:30")
        #expect(player.pressed.first == "play-pause" && result["pausedByCommand"] as? Bool == true)
        #expect(result["status"] as? String == "reached")
    }

    @Test func aPausedVideoIsNotPressedBeforeSwipingAndAShareUsesTheLength() async throws {
        let player = Player(at: 500, playing: false, shown: true)
        let result = try await Self.scrub(player, to: "40%", tolerance: "5")
        #expect(result["targetSeconds"] as? Int == 240 && result["pausedByCommand"] as? Bool == false)
        #expect(!player.pressed.contains("play-pause") && player.pressed.first?.hasPrefix("swipe-left") == true)
        #expect(abs(player.position - 240) <= 5)
    }

    /// An Apple TV that ignores quick swipes: the speed that moved nothing
    /// is dropped and the slower ones get there.
    @Test func quickSwipesThatMoveNothingAreNotUsedAgain() async throws {
        let player = Player(at: 0, playing: false, shown: true)
        player.secondsPerFullSwipe = [0.6: 30, 0.3: 55]
        let result = try await Self.scrub(player, to: "6:00")
        #expect(result["status"] as? String == "reached")
        let quick = player.pressed.filter { $0.hasSuffix("--seconds 0.2") || $0.hasSuffix("--seconds 0.1") }
        #expect(quick.count == 1)
    }

    /// The device's quickest swipes are erratic: the loop finishes on the
    /// slower ones and does not overshoot back and forth.
    @Test func theLastStepsUseASteadierSpeed() async throws {
        let player = Player(at: 456, playing: false, shown: true)
        player.erraticQuickShifts = [27, 209, 0]
        let result = try await Self.scrub(player, to: "1:00")
        #expect(result["status"] as? String == "reached")
        #expect(abs(player.position - 60) <= 10)
    }

    @Test func noPlayerSendsOnePauseAtMostAndSaysSo() async throws {
        let player = Player(at: 0, playing: false, shown: false)
        player.secondsPerFullSwipe = [:]
        // A screen with no player: play-pause shows nothing.
        let empty = PlayerPosition()
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await PlayerScrub.run(ScrubCommand(Self.simulator, to: "1:00"), read: { empty }, press: { player.press($0) }, wait: { _ in })
        }
        #expect(failure?.code == .targetUnresolved && failure?.inputSent == .possible && player.pressed == ["play-pause"])
        // Past the end is refused before any swipe.
        let short = Player(at: 10, length: 60, playing: false, shown: true)
        await #expect(throws: CommandFailure.self) { _ = try await Self.scrub(short, to: "2:00") }
        #expect(short.pressed.isEmpty)
    }

    @Test func theCommandAndTheMCPToolBuildTheSameRequest() throws {
        let request = try CLI.invocation(["scrub", "--to", "1:35", "--tolerance", "5", "--simulator", Self.simulator.identifier]).request
        guard case .scrub(let scrub) = request else { Issue.record("Not a scrub: \(request)"); return }
        #expect(scrub.goal == .seconds(95) && scrub.toleranceSeconds == 5 && !request.isReadOnly && request.signalContext == "simulator input")
        #expect(throws: (any Error).self) { try CLI.invocation(["scrub", "--to", "1:35", "--tolerance", "0", "--simulator", Self.simulator.identifier]) }
        let tool = try #require(MCPTools.definitions.first { $0.name == "scrub_video" })
        let args = try tool.command(["device": .string(Self.simulator.identifier), "to": "1:35", "tolerance_seconds": 5])
        #expect(try CLI.invocation(args).request == request)
    }
}
