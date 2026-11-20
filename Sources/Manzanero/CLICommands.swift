import ArgumentParser

// One type per operation. Each declares its operands and options and builds
// its `CommandRequest`, the one place that says what the command service runs.
// Operands stay text here: the operations' own validators convert and check
// them while the request is built, so their messages do not depend on the parser.

private let receiptCaveat = "A receipt reports what was sent, not what the app did; inspect the screen afterward."
private let coordinateNote = "Coordinates are normalized 0...1 from the top left of the current interface."

extension ManzaneroCLI {
    // MARK: Touch and keys

    struct Tap: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "tap", abstract: "Tap one point.",
                                                        discussion: "\(coordinateNote) \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Normalized x, 0...1.") var x: String
        @Argument(help: "Normalized y, 0...1.") var y: String
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "tap", [x, y]) }
    }

    struct LongPress: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "long-press", abstract: "Hold one touch, then release.",
                                                        discussion: "\(coordinateNote) \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Normalized x, 0...1.") var x: String
        @Argument(help: "Normalized y, 0...1.") var y: String
        @Argument(help: "Hold duration, 0.1...10 seconds.") var seconds: String
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "long-press", [x, y, seconds]) }
    }

    /// The operands of `swipe` and `drag`, which are one movement.
    struct PathOperands: ParsableArguments {
        @Argument(help: "Normalized start x.") var x1: String
        @Argument(help: "Normalized start y.") var y1: String
        @Argument(help: "Normalized end x.") var x2: String
        @Argument(help: "Normalized end y.") var y2: String
        @Argument(help: "Duration, 0.03...10 seconds.") var seconds: String
        var values: [String] { [x1, y1, x2, y2, seconds] }
    }

    struct Swipe: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "swipe", abstract: "Move one contact in a straight line (same as drag).",
                                                        discussion: "\(coordinateNote) \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var path: PathOperands
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "swipe", path.values) }
    }

    struct Drag: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "drag", abstract: "Move one contact in a straight line (same as swipe).",
                                                        discussion: "\(coordinateNote) \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var path: PathOperands
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "drag", path.values) }
    }

    struct Pinch: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "pinch", abstract: "Pinch or spread two horizontal contacts.",
            discussion: "Spans are fractions of the screen width and must differ; a smaller end span pinches in. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Normalized centre x.") var centerX: String
        @Argument(help: "Normalized centre y.") var centerY: String
        @Argument(help: "Start span, a positive fraction of the width.") var startSpan: String
        @Argument(help: "End span, a positive fraction of the width.") var endSpan: String
        @Argument(help: "Duration, 0.03...10 seconds.") var seconds: String
        func request(_ target: Target) throws -> CommandRequest {
            try .input(target, "pinch", [centerX, centerY, startSpan, endSpan, seconds])
        }
    }

    struct MultiTap: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "multi-tap", abstract: "Touch two to five points at once, then release after 80 ms.",
                                                        discussion: "\(coordinateNote) \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("Two to five x y pairs.", valueName: "x y")) var coordinates: [String]
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "multi-tap", coordinates) }
    }

    struct MultiDrag: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "multi-drag", abstract: "Move two to five contacts along straight paths.",
            discussion: "Each path is start-x start-y end-x end-y. Two crossing or overlapping paths are refused. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Duration, 0.03...10 seconds.") var seconds: String
        @Argument(help: ArgumentHelp("Two to five paths of four normalized numbers.", valueName: "path")) var paths: [String]
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "multi-drag", [seconds] + paths) }
    }

    struct Gesture: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "gesture", abstract: "Send one touch sequence of up to five contacts.",
            discussion: "The sequence is JSON: {\"frames\":[{\"ms\":0,\"touches\":[{\"id\":0,\"x\":0.5,\"y\":0.5}]},…]}. See docs/gesture-sequences.md. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "The JSON sequence.") var sequence: String
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "gesture", [sequence]) }
    }

    struct Button: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "button", abstract: "Press a hardware button.",
                                                        discussion: "lock toggles the display. side is the Apple Watch side button and action the Apple Watch Ultra's Action button (watch simulators only). \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("home, lock, volume-up, volume-down, or side or action (Apple Watch simulator).", valueName: "button"),
                  completion: .list(["home", "lock", "volume-up", "volume-down", "side", "action"])) var name: String
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "button", [name]) }
    }

    struct Batch: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "batch", abstract: "Run several commands for one device in one call, in order.",
            discussion: "The steps are a JSON array; each step is the words of one command without --device or --simulator, which the batch supplies, for example '[[\"press\",\"--id\",\"login\"],[\"wait\",\"--label\",\"Welcome\"]]'. At most 30 steps. Every step is checked before any runs. Each then runs as it would alone; the batch stops at the first step that fails or exits non-zero (a wait that times out), reports what ran and what did not, and exits 1. Earlier steps are not undone and nothing is repeated. handoff and batch cannot be steps. With --dry-run every step prints its plan.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "The JSON array of steps.") var steps: String
        func request(_ target: Target) throws -> CommandRequest { .batch(try BatchCommand(target: target, json: steps)) }
    }

    struct Remote: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "remote", abstract: "Press one Siri Remote button (Apple TV).",
            discussion: "The arrows move focus and select clicks the focused item (keyboard usages); menu goes back, home opens the Home Screen and play-pause toggles playback (consumer buttons). swipe-up, swipe-down, swipe-left and swipe-right draw one finger across the remote's touch surface: focus moves several items, where an arrow moves one; --travel and --seconds set a swipe's length and duration, and how far the focus then goes is the app's doing. sleep and wake are for a physical Apple TV: sleep opens Control Centre with the power button and presses Power Off there by accessibility, by its identifier, with no remote select; wake presses Home once on a device that gives no screenshot; each sends nothing when the device is already so. Apple TV has no touch screen, so touch commands are refused there. Any command to a sleeping Apple TV may switch it on, and its television with it. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("select, menu, home, play-pause, up, down, left, right, or swipe-up, swipe-down, swipe-left, swipe-right; sleep or wake on a physical Apple TV.", valueName: "button"),
                  completion: .list(AppleTVRemote.names)) var name: String
        @Option(help: ArgumentHelp("Hold the button this long, 0.08...3 seconds. On a simulator a 1.5 s hold on home opens Control Centre; on a device home cannot be held.", valueName: "seconds")) var hold: String?
        @Option(help: ArgumentHelp("A swipe's length as a share of the touch surface, 0.05...0.9 (default 0.5).", valueName: "share")) var travel: String?
        @Option(help: ArgumentHelp("A swipe's duration, 0.04...2 seconds (default 0.2).", valueName: "seconds")) var seconds: String?
        func request(_ target: Target) throws -> CommandRequest {
            try .input(target, "remote", [name] + (hold.map { [AppleTVRemote.holdOption, $0] } ?? [])
                + (travel.map { [AppleTVRemote.travelOption, $0] } ?? []) + (seconds.map { [AppleTVRemote.secondsOption, $0] } ?? []))
        }
    }

    struct Crown: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "crown", abstract: "Turn the Digital Crown (Apple Watch simulators).",
            discussion: "Units are the simulator's integer scroll deltas; positive scrolls toward later content. They are sent as events 1 s apart, slow enough that watchOS does not accelerate them: 200 units moved a SwiftUI digitalCrownRotation value by 1 at low sensitivity. Lists move by rows per event (Watch Settings: one row for each event of 100 units or more, none below 100), so use --events to scroll several rows. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("Non-zero integer units, -10000...10000; put -- before a negative amount.", valueName: "units")) var units: String
        @Option(help: ArgumentHelp("Split the units evenly over 1...20 events (default: the fewest of at most 1000 units).", valueName: "n")) var events: String?
        func request(_ target: Target) throws -> CommandRequest {
            guard target.platform == .simulator else {
                throw CommandFailure.unsupported("crown is implemented for Apple Watch simulators only; no device was contacted.")
            }
            return try .input(target, "crown", [units] + (events.map { [$0] } ?? []))
        }
    }

    struct Key: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "key", abstract: "Press one named key at the current focus.", discussion: receiptCaveat)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("return, escape, backspace, tab, space, up, down, left or right.", valueName: "key"),
                  completion: .list(["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"])) var name: String
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "key", [name]) }
    }

    struct TypeText: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text at the current focus in a named keyboard layout.",
            discussion: """
            Sends 1...512 characters as keyboard events; the clipboard is untouched. The device turns key codes into \
            characters with its own hardware-keyboard layout, so name that layout: --layout, else \
            $\(KeyboardLayout.environmentVariable), else us. Any character the layout produces with Shift, Option or one \
            dead key is accepted, plus tab and newline; the first one it cannot produce refuses the whole text before \
            anything is sent. List layout names with `manzanero keyboard-layouts`.

            A simulator's layout setting is read first: a different explicit layout is refused, and an automatic one is \
            reported as not checked. A physical device's layout cannot be read; the receipt says so. For text no layout \
            types, use set-value, which replaces a named element's whole value, or paste (physical), which replaces the \
            clipboard. \(receiptCaveat)
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Option(help: ArgumentHelp("Keyboard layout the device uses, such as us, spanish-iso, german or french (default: $\(KeyboardLayout.environmentVariable), else us).",
                                   valueName: "name")) var layout: String?
        @Argument(help: "The text; put -- before text that begins with '-'.") var text: String
        /// The explicit option wins over the environment; MCP passes no environment.
        func request(environment: [String: String]) throws -> CommandRequest {
            let fallback = environment[KeyboardLayout.environmentVariable].flatMap { $0.isEmpty ? nil : $0 } ?? KeyboardLayout.defaultName
            return try .input(target.resolve(environment), "type", [text, layout ?? fallback])
        }
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "type", [text, layout ?? KeyboardLayout.defaultName]) }
    }

    struct DetectLayout: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "detect-layout", abstract: "Find out which hardware-keyboard layout the device applies to typed keys.",
            discussion: """
            Types a short probe into one named, settable text field and compares what arrives with what each \
            keyboard layout on this Mac would type. The probe is computed from those layouts: letter, digit and \
            punctuation keys, with and without Shift, never Option, Return, Tab, space or arrows, ending with no \
            dead key pending. Steps: read the field (tree), set-value it to "x" (the press guards apply), type, read \
            it back, then delete what is there with backspaces; if it does not read as before, the first value is \
            set back with set-value. The receipt names the matching layouts (one, several that the probe cannot \
            tell apart, or none), the text that arrived, the --layout value to use and whether the restore was \
            confirmed. Autocorrection, auto-capitalisation, smart punctuation and input methods change what \
            arrives: use a plain field with them off, such as the probe app's probe.text.field. A simulator's own \
            layout setting is reported alongside. Sends input; changes no setting.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var selector: SelectorOptions
        func request(_ target: Target) throws -> CommandRequest {
            .detectLayout(try LayoutDetectionCommand(target, selector: selector))
        }
    }

    struct Paste: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "paste", abstract: "Paste Unicode text at the focused field (physical devices).",
            discussion: "Replaces the device clipboard with the text and does not restore it, then pastes once at the focused caret or selection. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "1...65536 UTF-8 bytes without NUL.") var text: String
        // A simulator refuses paste with its own message (SimulatorInput).
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "paste", [text]) }
    }

    struct Wake: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "wake", abstract: "Wake a physical device whose display is off.",
            discussion: "Presses the side button once, only if the display reads off twice, then Home once to leave the lock screen when no passcode is required. No press when the display is on or unknown; never enters a passcode.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Flag(help: "Do not press Home to leave the lock screen.") var noDismiss = false
        func request(_ target: Target) throws -> CommandRequest {
            try .input(target, DirectPhysicalWake.operation, noDismiss ? [DirectPhysicalWake.noDismissFlag] : [])
        }
    }

    // MARK: Accessibility

    struct Tree: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "tree", abstract: "Read the accessibility tree of one application.",
            discussion: "Without --pid: on a device the application at the primary display's centre, on a simulator the frontmost application.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Option(help: ArgumentHelp("Positive PID of the application to read.", valueName: "pid")) var pid: String?
        func request(_ target: Target) throws -> CommandRequest { try .input(target, "tree", pid.map { [$0] } ?? []) }
    }

    struct Press: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "press", abstract: "Press one element by exact identifier, label or value.",
            discussion: "Two fresh unique snapshots and live state, frame and hit checks precede one accessibility press. On a physical Apple TV a press by --id or --label first goes by Apple's Accessibility Inspector cursor (result route: inspector), which does not disturb the Mac's connection to the device and makes none of those checks; an element the cursor does not reach, --index and --with-value use the usual route, and the result says why in inspectorUnavailable. \(receiptCaveat)")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var selector: SelectorOptions
        func request(_ target: Target) throws -> CommandRequest { try .input(target, selector.operation("press"), selector.operands + selector.indexOperands) }
    }

    struct Scroll: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll one element into view by exact identifier, label or value.",
            discussion: "The element must already be in the snapshot, unless --search is given: a list that loads its rows as it moves holds only the rows near the screen. --search moves down one step at a time, or the way --toward names, reading the tree after each, until the element appears, the list stops moving or the steps run out; it does not move the list back. Visibility is observed afterward and reported separately.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var selector: SelectorOptions
        @Option(help: ArgumentHelp("Look forward for an element not yet in the tree, at most this many steps (1...200).", valueName: "steps")) var search: String?
        @Option(help: ArgumentHelp("The way --search moves: down (the default), up, left or right.", valueName: "direction")) var toward: String?
        func request(_ target: Target) throws -> CommandRequest {
            guard toward == nil || search != nil else {
                throw CommandFailure.usage("\(DirectAccessibilityAction.towardOption) belongs to scroll \(DirectAccessibilityAction.searchOption).")
            }
            return try .input(target, selector.operation("scroll"), selector.operands + selector.indexOperands
                       + (search.map { [DirectAccessibilityAction.searchOption, $0] } ?? [])
                       + (toward.map { [DirectAccessibilityAction.towardOption, $0] } ?? []))
        }
    }

    struct Wait: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait, read-only, until an element meets a condition.",
            discussion: "visible (default) needs exactly one visible match; gone means no match or none visible; value needs --value; focused needs the element to have focus (checked on Apple TV simulators). Exits 0 when met and 124 on timeout, with JSON on stdout either way. Sends no input.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var selector: SelectorOptions
        @Option(help: ArgumentHelp("visible, gone, enabled, disabled, value or focused.", valueName: "condition"),
                completion: .list(AccessibilityWait.conditionNames)) var until: String?
        @Option(parsing: .unconditional, help: ArgumentHelp("Exact expected value, for --until value.", valueName: "text")) var value: String?
        @Option(help: ArgumentHelp("Seconds, 0...60 (default 10).", valueName: "seconds")) var timeout: String?
        @Option(help: ArgumentHelp("Seconds between polls, 0.25...5 (default 0.5).", valueName: "seconds")) var interval: String?
        /// AccessibilityWait reads the options after the selector, by name.
        func request(_ target: Target) throws -> CommandRequest {
            try .input(target, selector.operation("wait"), selector.operands + selector.indexOperands
                + [("--until", until), ("--value", value), ("--timeout", timeout), ("--interval", interval)]
                    .flatMap { name, value in value.map { [name, $0] } ?? [] })
        }
    }

    struct SetValue: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "set-value", abstract: "Replace an element's whole value with Unicode text.",
            discussion: "Selection and guards are those of press; the element must report its value settable. No keyboard or clipboard is used; the value is read back once.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @OptionGroup var selector: SelectorOptions
        @Argument(help: "The new value, 1...65536 UTF-8 bytes without NUL.") var text: String
        func request(_ target: Target) throws -> CommandRequest {
            try .input(target, selector.operation("set-value"), selector.operands + [text] + selector.indexOperands)
        }
    }

    // MARK: Screen

    struct Screenshot: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "Save a PNG screenshot.",
            discussion: "A simulator with several displays (iPhone Duo) captures its primary display unless --display names another.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Output path ending in .png.", completion: .file(extensions: ["png"])) var output: String
        @Option(help: ArgumentHelp("Simulator display: name, device name or screen ID (see displays).", valueName: "display")) var display: String?
        func request(_ target: Target) throws -> CommandRequest {
            if target.platform == .simulator { return .simulatorDisplay(try .screenshot(target, output: output, display: display)) }
            _ = try SimulatorDisplays.validated(display, physical: true, operation: "screenshot")
            return .tool(try DeviceOperation(target, "screenshot", [output]))
        }
    }

    struct Fold: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "fold", abstract: "Close a foldable simulator (iPhone Duo) to the outer display.",
            discussion: "Sets the hinge to 0 degrees with the event Device Hub's hinge control sends, then reads the display information until the outer (primary) display is awake and the inner one is off, for at most 10 s. The receipt names the active display and whether that was observed. Refused on simulators without two integrated displays and on physical devices.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { try SimulatorHinge.request(target, "fold") }
    }

    struct Unfold: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "unfold", abstract: "Open a foldable simulator (iPhone Duo) to the inner display.",
            discussion: "Sets the hinge to 180 degrees, then reads the display information until the inner display is awake and the outer one is off, for at most 10 s. Unfolded, the interface is on the inner display in landscape. The receipt names the active display and whether that was observed.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { try SimulatorHinge.request(target, "unfold") }
    }

    struct Hinge: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "hinge", abstract: "Read or set a foldable simulator's hinge angle (iPhone Duo).",
            discussion: "Without an angle, reads one sample of the hinge angle (CoreDevice's hinge-angle stream, closed after the first sample) with the active display; sends no input. With an angle, 0 is closed and 180 fully open; the simulator animates to it. Whether an intermediate angle swaps the display depends on how the hinge got there (0 to 110 in one step unfolded, the same in small steps did not), so the receipt only reports the display awake right after sending. Use fold or unfold for a confirmed display.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("Angle in degrees, 0...180; omit it to read the angle.", valueName: "degrees")) var degrees: String?
        func request(_ target: Target) throws -> CommandRequest {
            guard let degrees else { return try SimulatorHinge.request(target, SimulatorHinge.angleOperation) }
            return try SimulatorHinge.request(target, "hinge", [degrees])
        }
    }

    struct Displays: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "displays", abstract: "List a simulator's displays (simulators).",
            discussion: "Name, screen ID, size, backlight and active state, and which display is primary, read from the simulator's display information. Sends no input.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .simulatorDisplay(try .list(target)) }
    }

    struct Screen: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "screen", abstract: "Capture the screen and describe it through accessibility or OCR.",
            discussion: "auto prefers a useful accessibility tree, then Vision OCR, and reports image-only when both fail.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "auto (default), tree or ocr.", completion: .list(["auto", "tree", "ocr"])) var mode: String?
        @Option(help: ArgumentHelp("Simulator display: name, device name or screen ID (see displays); the tree follows only the display the interface is on.", valueName: "display")) var display: String?
        func request(_ target: Target) throws -> CommandRequest {
            var screen = try ScreenCommand(platform: target.platform.rawValue, device: target.identifier, mode: mode)
            screen.display = try SimulatorDisplays.validated(display, physical: target.platform == .physical, operation: "screen")
            return .screen(screen)
        }
    }

    struct Record: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "record", abstract: "Record the screen to a new MP4 file.",
            discussion: "The destination must not exist and its parent directory must. --backend coredevice records a physical device in process.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "New output path ending in .mp4.", completion: .file(extensions: ["mp4"])) var output: String
        @Argument(help: "Duration, 1...300 seconds.") var seconds: String
        @Argument(help: "h264 (default) or hevc.", completion: .list(["h264", "hevc"])) var codec: String?
        @Option(help: ArgumentHelp("Physical recording backend: devicectl (default) or coredevice.", valueName: "backend"),
                completion: .list(["devicectl", "coredevice"])) var backend: String?
        @Option(help: ArgumentHelp("Simulator display: name, device name or screen ID (see displays).", valueName: "display")) var display: String?
        func request(_ target: Target) throws -> CommandRequest {
            var recording = try RecordingCommand(physical: target.platform == .physical, device: target.identifier, output: output,
                                                 seconds: seconds, codec: codec, backend: backend)
            recording.display = try SimulatorDisplays.validated(display, physical: target.platform == .physical, operation: "record")
            return .record(recording)
        }
    }

    struct Frames: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "frames", abstract: "Save live screen frames as numbered JPEG files (physical devices).",
            discussion: """
            Opens one in-process video stream (as record --backend coredevice does) and saves frames as \
            frame-0001.jpg, frame-0002.jpg, … with an index, \(FramesCommand.indexName): file, time offset from the first \
            frame, pixel size and bytes of each. Repeated screenshots without a devicectl run per image. Stops at --count \
            frames (default \(FramesCommand.defaultCount); at most \(FramesCommand.maximumCount)), after --seconds from the \
            first frame, or when \(FramesCommand.byteLimit / (1024 * 1024)) MiB have been written, whichever comes first. \
            --interval saves the first frame that arrives at or after each multiple of that many milliseconds from \
            the first frame, so a late frame does not delay the rest; saved frames are never closer than \
            \(FramesCommand.minimumSpacingMilliseconds) ms, and a still screen still delivers frames. The directory is created if missing (its parent must exist); \
            a non-empty one is refused unless --overwrite. The first frame must arrive within \
            \(FramesCommand.firstFrameBudgetSeconds) s. SIGINT or SIGTERM stops the stream, keeps the frames saved so far \
            and writes the index. Frames are in the display's native orientation. Simulators: use screenshot.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Directory for the frames and the index.", completion: .directory) var directory: String
        @Option(help: ArgumentHelp("Frames to save, 1...\(FramesCommand.maximumCount) (default \(FramesCommand.defaultCount), or \(FramesCommand.maximumCount) with --seconds alone).", valueName: "n")) var count: String?
        @Option(help: ArgumentHelp("Stop this long after the first frame, 0.5...300 seconds.", valueName: "seconds")) var seconds: String?
        @Option(help: ArgumentHelp("Save one frame per this many milliseconds, 0...60000 (default 0: every frame, at most 30 per second).", valueName: "ms")) var interval: String?
        @Flag(help: "Write into a non-empty directory, replacing same-named frames and the index.") var overwrite = false
        func request(_ target: Target) throws -> CommandRequest {
            guard target.platform == .physical else {
                throw CommandFailure.unsupported("frames reads a physical device's video stream; for a simulator use screenshot. No device was contacted.")
            }
            return .frames(try FramesCommand(device: target.identifier, directory: directory, count: count, seconds: seconds,
                                             interval: interval, overwrite: overwrite))
        }
    }

    // MARK: Apps and files

    struct Apps: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "apps", abstract: "List installed apps.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "apps")) }
    }

    struct Launch: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "launch", abstract: "Launch an app.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Bundle identifier.") var bundleID: String
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "launch", [bundleID])) }
    }

    struct Terminate: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "terminate", abstract: "Terminate an app.",
                                                        discussion: "A device takes a PID (see processes); a simulator a bundle identifier.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: ArgumentHelp("PID (device) or bundle identifier (simulator).", valueName: "pid-or-bundle-id")) var app: String
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "terminate", [app])) }
    }

    struct Install: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Install an app bundle.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Path of the .app.", completion: .directory) var appPath: String
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "install", [appPath])) }
    }

    struct Uninstall: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstall an app and delete its data.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Bundle identifier.") var bundleID: String
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "uninstall", [bundleID])) }
    }

    struct OpenURL: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "open-url", abstract: "Open a URL.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "An absolute URL with a scheme.") var url: String
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "open-url", [url])) }
    }

    struct Files: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "files", abstract: "List or copy files in an app's data container (physical devices).",
            discussion: "Remote paths are relative to the container; '.' is its root. Copies may overwrite the destination.",
            subcommands: [List.self, Pull.self, Push.self])

        struct List: TargetedCommand {
            static let configuration = CommandConfiguration(commandName: "list", abstract: "List one directory, without recursion.")
            @OptionGroup var target: TargetOptions
            @OptionGroup var common: CommonOptions
            @Argument(help: "Bundle identifier.") var bundleID: String
            @Argument(help: "Relative directory; '.' for the root.") var remotePath: String
            func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "files", [bundleID, remotePath])) }
        }

        struct Pull: TargetedCommand {
            static let configuration = CommandConfiguration(commandName: "pull", abstract: "Copy a file from the container to the Mac.")
            @OptionGroup var target: TargetOptions
            @OptionGroup var common: CommonOptions
            @Argument(help: "Bundle identifier.") var bundleID: String
            @Argument(help: "Relative path in the container.") var remotePath: String
            @Argument(help: "Destination on the Mac.", completion: .file()) var localPath: String
            func request(_ target: Target) throws -> CommandRequest {
                .tool(try DeviceOperation(target, "pull", [bundleID, remotePath, localPath]))
            }
        }

        struct Push: TargetedCommand {
            static let configuration = CommandConfiguration(commandName: "push", abstract: "Copy a file from the Mac into the container.")
            @OptionGroup var target: TargetOptions
            @OptionGroup var common: CommonOptions
            @Argument(help: "Bundle identifier.") var bundleID: String
            @Argument(help: "Source on the Mac.", completion: .file()) var localPath: String
            @Argument(help: "Relative path in the container.") var remotePath: String
            func request(_ target: Target) throws -> CommandRequest {
                .tool(try DeviceOperation(target, "push", [bundleID, localPath, remotePath]))
            }
        }
    }

    struct Reports: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reports", abstract: "List or download saved crash and diagnostic reports (physical devices).",
            discussion: "Paths are relative to the device's crash logs; '.' is their root.",
            subcommands: [List.self, Get.self])

        struct List: TargetedCommand {
            static let configuration = CommandConfiguration(commandName: "list", abstract: "List one directory of reports, without recursion.")
            @OptionGroup var target: TargetOptions
            @OptionGroup var common: CommonOptions
            @Argument(help: "Relative directory (default '.').") var directory: String?
            func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "reports", directory.map { [$0] } ?? [])) }
        }

        struct Get: TargetedCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Download one report to the Mac.",
                                                            discussion: "May overwrite the destination.")
            @OptionGroup var target: TargetOptions
            @OptionGroup var common: CommonOptions
            @Argument(help: "Relative report path.") var remotePath: String
            @Argument(help: "Destination on the Mac.", completion: .file()) var localPath: String
            func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "report", [remotePath, localPath])) }
        }
    }

    struct BuildRun: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "build-run", abstract: "Build an Xcode project or workspace, then install and launch its app.",
            discussion: """
            Runs the project's build scripts and requires xcsift on PATH. Physical builds use the signing assets \
            already on the Mac. --allow-provisioning-updates lets Xcode use the account in its settings to create \
            or change certificates, app IDs and profiles on Apple's developer services; \
            --allow-device-registration also registers the device with the team. Both are physical-only and off by default.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "An .xcodeproj or .xcworkspace.", completion: .file(extensions: ["xcodeproj", "xcworkspace"])) var project: String
        @Argument(help: "The scheme to build.") var scheme: String
        @Option(help: "Build configuration (default Debug).") var configuration: String?
        @Option(help: ArgumentHelp("The application target, when the scheme builds several.", valueName: "name")) var appTarget: String?
        @Flag(help: "Let Xcode create or update signing assets on Apple's developer services (physical).") var allowProvisioningUpdates = false
        @Flag(help: "Also let Xcode register this device with the team; needs --allow-provisioning-updates.") var allowDeviceRegistration = false
        func request(_ target: Target) throws -> CommandRequest {
            .buildRun(try BuildRunCommand(physical: target.platform == .physical, device: target.identifier, project: project, scheme: scheme,
                                          configuration: configuration, appTarget: appTarget,
                                          allowProvisioningUpdates: allowProvisioningUpdates, allowDeviceRegistration: allowDeviceRegistration))
        }
    }

    // MARK: Diagnostics

    struct Logs: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "logs", abstract: "Capture one app's unified-log entries (simulators).",
            discussion: """
            Give one time selection (--seconds, --last, or --start with optional --end) and one target (--bundle, \
            --pid or --process). Apple's log tool runs in the simulator with a predicate built from these fields; \
            --last and --start read persisted entries, which exclude debug. Messages can contain private data.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Option(help: ArgumentHelp("Stream from now for 1...60 seconds.", valueName: "seconds")) var seconds: String?
        @Option(help: ArgumentHelp("Read the last 1...3600 seconds of persisted entries.", valueName: "seconds")) var last: String?
        @Option(help: ArgumentHelp("ISO-8601 start of a persisted window.", valueName: "date")) var start: String?
        @Option(help: ArgumentHelp("ISO-8601 end of the window; needs --start.", valueName: "date")) var end: String?
        @Option(help: ArgumentHelp("Bundle identifier of the app.", valueName: "bundle-id")) var bundle: String?
        @Option(help: ArgumentHelp("PID of the app.", valueName: "pid")) var pid: String?
        @Option(help: ArgumentHelp("Process name of the app.", valueName: "name")) var process: String?
        @Option(help: ArgumentHelp("Only this subsystem.", valueName: "subsystem")) var subsystem: String?
        @Option(help: ArgumentHelp("Only this category; needs --subsystem.", valueName: "category")) var category: String?
        @Option(help: ArgumentHelp("default (default), info or debug.", valueName: "level"),
                completion: .list(LogCapture.Level.allCases.map(\.rawValue))) var level: String?
        @Option(help: ArgumentHelp("At most this many entries (default 2000, at most 10000).", valueName: "n")) var maxEntries: String?
        @Option(help: ArgumentHelp("At most this many bytes (default 1 MiB, at most 8 MiB).", valueName: "n")) var maxBytes: String?
        @Option(help: ArgumentHelp("Write every kept entry as NDJSON to this new file.", valueName: "path"), completion: .file()) var output: String?
        func request(_ target: Target) throws -> CommandRequest {
            let options = DiagnosticOptions(values: [
                "--seconds": seconds, "--last": last, "--start": start, "--end": end, "--bundle": bundle, "--pid": pid,
                "--process": process, "--subsystem": subsystem, "--category": category, "--level": level,
                "--max-entries": maxEntries, "--max-bytes": maxBytes, "--output": output])
            return .diagnostics(try .make(physical: target.platform == .physical, device: target.identifier, operation: "logs", options: options))
        }
    }

    struct Console: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "console", abstract: "Relaunch an app and return the tails of its stdout and stderr.",
            discussion: """
            Arguments after -- are passed to the app. --os-log mirrors its os_log lines (info and above) to \
            stderr. Simulator: output goes to files under tmp/ and the app keeps running unless --terminate. \
            Physical: the app is ended by SIGINT at the duration. Launches an app, so it is not read-only.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "Bundle identifier.") var bundleID: String
        @Option(help: ArgumentHelp("Capture duration, 1...60 seconds.", valueName: "seconds")) var seconds: String
        @Option(help: ArgumentHelp("Bytes kept per stream, 1024...1048576 (default 65536).", valueName: "n")) var maxBytes: String?
        @Flag(help: "Mirror the app's os_log lines to its stderr.") var osLog = false
        @Flag(help: "Simulator: terminate the app at the end.") var terminate = false
        @Argument(parsing: .postTerminator, help: ArgumentHelp("Arguments for the app, after --.", valueName: "app-argument")) var appArguments: [String] = []
        func request(_ target: Target) throws -> CommandRequest {
            let options = DiagnosticOptions(values: ["--seconds": seconds, "--max-bytes": maxBytes],
                                            flags: ["--os-log": osLog, "--terminate": terminate],
                                            positional: [bundleID], trailing: appArguments)
            return .diagnostics(try .make(physical: target.platform == .physical, device: target.identifier, operation: "console", options: options))
        }
    }

    struct LastCrash: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "last-crash", abstract: "Summarise the newest crash report for one app.",
            discussion: "Give exactly one of --bundle or --process. Simulator reports are read from the Mac; device reports are listed and downloaded through reports.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Option(help: ArgumentHelp("Bundle identifier of the app.", valueName: "bundle-id")) var bundle: String?
        @Option(help: ArgumentHelp("Process name of the app.", valueName: "name")) var process: String?
        @Option(help: ArgumentHelp("Ignore reports older than this ISO-8601 date.", valueName: "date")) var since: String?
        @Option(help: ArgumentHelp("Copy the report into this existing directory.", valueName: "dir"), completion: .directory) var download: String?
        func request(_ target: Target) throws -> CommandRequest {
            let options = DiagnosticOptions(values: ["--bundle": bundle, "--process": process, "--since": since, "--download": download])
            return .diagnostics(try .make(physical: target.platform == .physical, device: target.identifier, operation: "last-crash", options: options))
        }
    }

    // MARK: Device state

    struct Devices: CLICommand {
        static let configuration = CommandConfiguration(commandName: "devices", abstract: "List physical devices, or simulators, as JSON.",
                                                        discussion: "Each physical device carries ownTunnel: cable, network or unavailable, which says whether a tunnel of the tool's own can be opened to it now. It is read from the Mac's usbmuxd, which lists a device on its cable, or on the network once it has been trusted over a cable and network access is on; no device is contacted. The same list is printed on stderr after the JSON. A device that is not listed, such as an Apple TV, is reached over Apple's tunnel.")
        @OptionGroup var common: CommonOptions
        @Flag(help: "List available simulators instead of physical devices.") var simulators = false
        func request(environment: [String: String]) throws -> CommandRequest { .devices(simulators: simulators) }
    }

    struct Details: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "details", abstract: "Show CoreDevice details (physical devices).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "details")) }
    }

    struct Processes: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "processes", abstract: "List running processes (physical devices).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "processes")) }
    }

    struct ClearQuarantine: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: DeviceQuarantine.operation,
            abstract: "Allow input again after an input whose release is unknown.",
            discussion: """
            A device is quarantined on this Mac when a touch, button or key input ended with an unknown outcome, \
            or when the process sending it exited before releasing (a crash or a kill): a contact, key or button \
            may still be held. Input is then refused with code device-quarantined, in every manzanero process; \
            tree, screen, screenshot and recording still work. Inspect the device, then run this. It removes the \
            mark and sends nothing to the device: it does not release anything held there.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest {
            guard !target.identifier.isEmpty, !target.identifier.hasPrefix("-") else { throw CommandFailure.usage("Provide a valid device identifier.") }
            return .clearQuarantine(target)
        }
    }

    struct Readiness: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "readiness", abstract: "Check CoreDevice prerequisites and observe display and passcode state (physical devices).",
            discussion: "Exits 1 unless the prerequisites are present. Does not verify UI Automation or prove that the UI is unlocked.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        /// A simulator has no readiness report: devicectl's refusal applies.
        func request(_ target: Target) throws -> CommandRequest {
            guard target.platform == .physical else { return .tool(try DeviceOperation(target, "readiness")) }
            guard !target.identifier.isEmpty, !target.identifier.hasPrefix("-") else { throw CommandFailure.usage("Provide a valid device identifier.") }
            return .readiness(device: target.identifier)
        }
    }

    struct MediaStatus: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "media-status", abstract: "Read native media support and status (physical devices).",
                                                        discussion: "Never starts or stops a stream.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest {
            guard target.platform == .physical else { return .tool(try DeviceOperation(target, "media-status")) }
            guard !target.identifier.isEmpty, !target.identifier.hasPrefix("-") else { throw CommandFailure.usage("Usage: media-status --device <UDID>") }
            return .mediaStatus(device: target.identifier)
        }
    }

    struct Boot: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "boot", abstract: "Boot a simulator.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "boot")) }
    }

    struct Shutdown: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "shutdown", abstract: "Shut down a simulator; running apps are interrupted.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        func request(_ target: Target) throws -> CommandRequest { .tool(try DeviceOperation(target, "shutdown")) }
    }

    struct Handoff: TargetedCommand {
        static let configuration = CommandConfiguration(commandName: "handoff", abstract: "Ask a person to do a step on the device, then wait until it is done.",
            discussion: """
            Automation of this device pauses meanwhile. With --until the device is watched and the handoff ends by \
            itself when it shows the condition, or at the timeout; nobody has to answer, no terminal is needed, and \
            a step that is already done returns at once. unlocked (display on, no passcode required) and paired \
            (connected and paired) are for physical devices; visible, gone, enabled, disabled, value and focused \
            are wait's conditions and take --id, --label or --with-value, for example --until gone --label Allow for a \
            permission prompt. Without --until a person answers in the terminal (done, decline, cancel) and the \
            answer is not verified on the device. Do not put secrets in the message.
            """)
        @OptionGroup var target: TargetOptions
        @OptionGroup var common: CommonOptions
        @Argument(help: "What the person should do, 1...2048 UTF-8 bytes.") var message: String
        @Argument(help: "Seconds to wait, 1...3600 (default 300).") var timeout: String?
        @Option(help: ArgumentHelp("End when the device shows this: \(HandoffCondition.names.joined(separator: ", ")).", valueName: "condition"),
                completion: .list(HandoffCondition.names)) var until: String?
        @Option(parsing: .unconditional, help: ArgumentHelp("Element to watch, by exact accessibility identifier.", valueName: "identifier")) var id: String?
        @Option(parsing: .unconditional, help: ArgumentHelp("Element to watch, by exact accessibility label.", valueName: "label")) var label: String?
        @Option(parsing: .unconditional, help: ArgumentHelp("Element to watch, by its exact current value.", valueName: "value")) var withValue: String?
        @Option(help: ArgumentHelp("Position among several matching elements, counted from 1.", valueName: "position")) var index: String?
        @Option(parsing: .unconditional, help: ArgumentHelp("Exact expected value, for --until value.", valueName: "text")) var value: String?
        func request(_ target: Target) throws -> CommandRequest {
            .handoff(try HandoffCommand(platform: target.platform.rawValue, device: target.identifier, message: message, timeout: timeout,
                                        until: until, id: id, label: label, withValue: withValue, index: index, value: value))
        }
    }

    // MARK: Host

    struct Doctor: CLICommand {
        static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check Xcode, device services and private interfaces on this Mac.",
                                                        discussion: "Contacts no device.")
        @OptionGroup var common: CommonOptions
        func request(environment: [String: String]) throws -> CommandRequest { .doctor }
    }

    struct KeyboardLayouts: CLICommand {
        static let configuration = CommandConfiguration(commandName: "keyboard-layouts", abstract: "List the keyboard layout names type accepts.",
            discussion: "The layouts this Mac ships, as JSON: name (for --layout), macOS identifier and localized name. Names match ignoring case, spaces and punctuation, so iOS names such as \"Spanish - ISO\" work too. Contacts no device.")
        @OptionGroup var common: CommonOptions
        func request(environment: [String: String]) throws -> CommandRequest { .keyboardLayouts }
    }

    struct OCR: CLICommand {
        static let configuration = CommandConfiguration(commandName: "ocr", abstract: "Recognize text in an image, with normalized bounds.")
        @OptionGroup var common: CommonOptions
        @Argument(help: "Image path.", completion: .file()) var imagePath: String
        func request(environment: [String: String]) throws -> CommandRequest { .ocr(path: imagePath) }
    }

    struct DecodeAXArchive: CLICommand {
        static let configuration = CommandConfiguration(commandName: "decode-ax-archive", abstract: "Inspect a saved accessibility keyed archive offline.")
        @OptionGroup var common: CommonOptions
        @Argument(help: "Local plist path.", completion: .file()) var path: String
        func request(environment: [String: String]) throws -> CommandRequest {
            guard !path.isEmpty else { throw CommandFailure.usage("Usage: decode-ax-archive <local-plist>") }
            return .decodeArchive(path: path)
        }
    }

    struct MCPServe: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve the MCP tools over stdio.",
            discussion: "End of input, SIGINT or SIGTERM cancels running tools and waits for their cleanup; a forced exit cannot guarantee release.")
        @OptionGroup var common: CommonOptions
    }
}
