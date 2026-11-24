import Foundation

/// `scrub --to <time>`: Apple's player on an Apple TV moved to a time, as a
/// person does it, each step read back from the player itself
/// (docs/other-families.md#seeking-in-apples-player).
///
/// Measured on a tvOS simulator and on the Apple TV 4K (2026-11-23 and
/// 2026-11-24): `play-pause` pauses and shows the controls; a swipe while
/// paused moves only a preview, which `select` commits and plays from; the
/// tree names the controls' elements by identifiers that do not depend on
/// the language: `AXElapsedTime` and `AXRemainingTime` as `mm:ss` (or
/// `h:mm:ss`), and the preview's `Elapsed Time Scrubbing Marker`.
///
/// The command reads, pauses when the controls are hidden, swipes the
/// preview toward the target (each swipe's length set from how far the last
/// one moved), reads the preview after every swipe, and commits with
/// `select`. It never presses without a fresh reading, and stops after a
/// bounded number of swipes.
struct ScrubCommand: Sendable, Equatable {
    static let operation = "scrub"
    static let toleranceRange = 1...120
    static let defaultTolerance = 10
    /// Swipes before the command gives up and commits where the preview is.
    static let maximumSwipes = 20
    /// Swipe durations, slowest first.
    static let swipeSpeeds = [0.6, 0.3, 0.2, 0.1]
    static var swipeSeconds: Double { swipeSpeeds[0] }
    static let travelRange = 0.05...0.9
    static let firstTravel = 0.3

    let target: Target
    /// What `--to` gave: seconds from the start, or a share of the length.
    enum Goal: Sendable, Equatable {
        case seconds(Int)
        case fraction(Double)
    }
    let goal: Goal
    let toleranceSeconds: Int

    init(_ target: Target, to text: String, tolerance: String? = nil) throws {
        self.target = target
        goal = try Self.parseGoal(text)
        if let tolerance {
            guard let value = Int(tolerance), Self.toleranceRange.contains(value) else {
                throw CommandFailure.usage("--tolerance takes whole seconds in \(Self.toleranceRange.lowerBound)...\(Self.toleranceRange.upperBound).")
            }
            toleranceSeconds = value
        } else {
            toleranceSeconds = Self.defaultTolerance
        }
    }

    /// `95` (seconds), `1:35`, `1:02:03`, or `40%` of the length.
    static func parseGoal(_ text: String) throws -> Goal {
        if text.hasSuffix("%"), let share = Double(text.dropLast()), (0...100).contains(share) { return .fraction(share / 100) }
        if let seconds = clock(text) ?? Int(text).flatMap({ $0 >= 0 ? $0 : nil }) { return .seconds(seconds) }
        throw CommandFailure.usage("scrub --to takes seconds (95), mm:ss (1:35), h:mm:ss (1:02:03) or a share of the length (40%).")
    }

    /// `mm:ss` or `h:mm:ss`, as the player writes its times; a leading `-`
    /// (the remaining time) is ignored.
    static func clock(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let values = Optional(parts.compactMap { Int($0) }), values.count == parts.count,
              values.allSatisfy({ $0 >= 0 }), values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    var plan: [String: Any] {
        let goalJSON: Any = switch goal {
        case .seconds(let seconds): ["seconds": seconds]
        case .fraction(let share): ["fraction": share]
        }
        return ["operation": Self.operation, "platform": target.platform.rawValue, "device": target.identifier, "to": goalJSON,
                "toleranceSeconds": toleranceSeconds, "maximumSwipes": Self.maximumSwipes,
                "execution": "Read the tree for Apple's player's AXElapsedTime and AXRemainingTime; if they are absent press play-pause once (pause, controls shown) and read again; swipe the paused preview toward the target, each swipe's length from how far the last one at its speed moved and its duration one of \(Self.swipeSpeeds.map { "\($0)" }.joined(separator: ", ")) s (quicker while a full swipe covers less than a third of the way, never again a speed that moved nothing), reading the preview (Elapsed Time Scrubbing Marker, else AXElapsedTime) after each, at most \(Self.maximumSwipes); then select once to commit, which plays from there, and read the position. Nothing is pressed without a reading before it."]
    }
}

/// The player's times read from one tree.
struct PlayerPosition: Equatable {
    var elapsed: Int?
    var remaining: Int?
    /// The preview while scrubbing.
    var marker: Int?

    static let elapsedIdentifier = "AXElapsedTime"
    static let remainingIdentifier = "AXRemainingTime"
    static let markerIdentifier = "Elapsed Time Scrubbing Marker"

    init(elapsed: Int? = nil, remaining: Int? = nil, marker: Int? = nil) {
        self.elapsed = elapsed; self.remaining = remaining; self.marker = marker
    }

    /// From a tree's JSON: the nodes with those identifiers, by label.
    init(tree: Data) {
        let nodes = ((try? JSONSerialization.jsonObject(with: tree)) as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        func time(_ identifier: String) -> Int? {
            nodes.first { $0["identifier"] as? String == identifier && ($0["label"] as? String).flatMap(ScrubCommand.clock) != nil }
                .flatMap { ($0["label"] as? String).flatMap(ScrubCommand.clock) }
        }
        self.init(elapsed: time(Self.elapsedIdentifier), remaining: time(Self.remainingIdentifier), marker: time(Self.markerIdentifier))
    }

    var shown: Bool { elapsed != nil }
    /// Where the preview is: the marker while it shows, else the elapsed time.
    var preview: Int? { marker ?? elapsed }
    var length: Int? { elapsed.flatMap { elapsed in remaining.map { elapsed + $0 } } }
}

/// The loop, with the device behind two closures: one tree read, and one
/// remote press (`[name] + options`). Tests drive it with a fake player.
enum PlayerScrub {
    /// How far apart two readings are taken to tell playing from paused:
    /// the player's times have whole seconds.
    static let playingCheck = Duration.milliseconds(1500)
    /// After the command's play-pause: readings a second apart until the
    /// controls show.
    static let controlsWait = Duration.seconds(1)
    static let controlsReads = 3

    static func run(_ command: ScrubCommand, isolation: isolated (any Actor)? = #isolation, read: () async throws -> PlayerPosition,
                    press: ([String]) async throws -> Void,
                    wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> [String: Any] {
        var steps: [[String: Any]] = []
        var pressed = false
        // A failure after a press leaves the player changed.
        func send(_ words: [String]) async throws {
            do { try await press(words); pressed = true }
            catch let failure as CommandFailure where pressed { throw failure.inputPossiblySent() }
        }
        func look() async throws -> PlayerPosition {
            do { return try await read() }
            catch let failure as CommandFailure where pressed { throw failure.inputPossiblySent() }
        }
        var position = try await look()
        var pausedByCommand = false
        // Controls on screen do not mean paused (they show for a while after
        // a launch or a press, measured on a simulator on 2026-11-24): a
        // second reading tells, and a swipe only scrubs while paused.
        var playing = false
        if position.shown, let first = position.elapsed {
            try await wait(playingCheck)
            let again = try await look()
            if let second = again.elapsed, second > first { playing = true }
            position = again
        }
        if !position.shown || playing {
            try await send(["play-pause"])
            pausedByCommand = true
            // The controls take a moment to appear after the pause.
            for _ in 0..<controlsReads {
                try await wait(controlsWait)
                position = try await look()
                if position.shown { break }
            }
            steps.append(["press": "play-pause", "preview": position.preview.map { $0 as Any } ?? NSNull()])
        }
        guard let start = position.preview else {
            throw CommandFailure(.targetUnresolved, "No player's time was found in the tree (AXElapsedTime)\(pausedByCommand ? " after one play-pause, which was sent" : ""); scrub works on Apple's player with its controls. \(pausedByCommand ? "" : "Nothing was sent.")",
                                 inputSent: pausedByCommand ? .possible : .none)
        }
        let target: Int
        switch command.goal {
        case .seconds(let seconds): target = seconds
        case .fraction(let share):
            guard let length = position.length else {
                throw CommandFailure(.targetUnresolved, "The player's length was not readable (AXRemainingTime), so a share of it has no time.", inputSent: pressed ? .possible : .none)
            }
            target = Int((Double(length) * share).rounded())
        }
        if let length = position.length, target > length {
            throw CommandFailure.usage("scrub --to \(target) s is past the end (\(length) s).")
        }
        var current = start
        // A quicker swipe moves the preview further (a tvOS simulator on
        // 2026-11-24: a full-length swipe moved it 30 s in 0.6 s, 71 s in
        // 0.2 s and 132 s in 0.1 s), and an Apple TV can ignore a quick one.
        // So the speed is chosen too: quicker while a full swipe covers less
        // than a third of the way, slower for short ones, and a speed that
        // moved nothing is not used again. Seconds of preview per unit of
        // travel are learnt for each speed.
        let speeds = ScrubCommand.swipeSpeeds
        var speed = 0
        var fastest = speeds.count - 1
        var secondsPerTravel: [Double?] = Array(repeating: nil, count: speeds.count)
        var swipes = 0
        while abs(target - current) > command.toleranceSeconds, swipes < ScrubCommand.maximumSwipes {
            let distance = Double(target - current)
            let maximum = ScrubCommand.travelRange.upperBound
            if let rate = secondsPerTravel[speed], abs(distance) > 3 * rate * maximum, speed < fastest {
                speed += 1
            } else {
                // Near the end the slower, steadier speeds: the Apple TV 4K
                // moved the preview 27, 209 and 0 s with three 0.1 s swipes.
                while speed > 0, let slower = secondsPerTravel[speed - 1], abs(distance) <= slower * maximum * 1.5 { speed -= 1 }
            }
            var travel = secondsPerTravel[speed].map { abs(distance) / $0 }
                ?? (speed == 0 ? ScrubCommand.firstTravel : maximum)
            travel = min(max(travel, ScrubCommand.travelRange.lowerBound), maximum)
            let words = [distance > 0 ? "swipe-right" : "swipe-left", "--travel", String(format: "%.2f", travel),
                         "--seconds", String(speeds[speed])]
            try await send(words)
            swipes += 1
            let after = try await look()
            guard let moved = after.preview else { break }
            let shift = Double(abs(moved - current))
            if shift > 0 {
                secondsPerTravel[speed] = shift / travel
            } else if speed > 0 {
                // Ignored at this speed: never quicker than the one below.
                fastest = speed - 1
                speed -= 1
            } else if let known = secondsPerTravel[0] {
                secondsPerTravel[0] = known / 2
            }
            steps.append(["press": words.joined(separator: " "), "preview": moved])
            // Past the target: slower from now on.
            if (target - moved).signum() != (target - current).signum(), abs(target - moved) > command.toleranceSeconds, speed > 0 {
                fastest = min(fastest, speed - 1)
                speed -= 1
            }
            current = moved
        }
        try await send(["select"])
        let landed = try await look()
        steps.append(["press": "select", "preview": landed.preview.map { $0 as Any } ?? NSNull()])
        let reached = landed.preview ?? current
        return ["operation": ScrubCommand.operation, "device": command.target.identifier, "platform": command.target.platform.rawValue,
                "status": abs(target - reached) <= command.toleranceSeconds ? "reached" : "not-reached",
                "targetSeconds": target, "startSeconds": start, "reachedSeconds": reached,
                "lengthSeconds": position.length.map { $0 as Any } ?? NSNull(),
                "toleranceSeconds": command.toleranceSeconds, "swipes": swipes, "pausedByCommand": pausedByCommand,
                "steps": steps, "verified": landed.preview != nil,
                "note": "Committed with select, which plays from the new position. Times are the player's own, read from its controls."]
    }
}
