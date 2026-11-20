# Probe fixture app

The probe app is a small iOS app of this project's own that reports what the device actually received, so Manzanero's operations can be checked against ground truth instead of screenshots. It holds three probes: the touch probe described first, whose accessibility identifiers are namespaced `probe.touch.*`; the [log probe](#log-probe), namespaced `probe.log.*`, which writes known lines for [`logs` and `console`](app-logs.md); and the [text probe](#text-probe), namespaced `probe.text.*`, which shows what text entry reached a text field. A fourth, the [permission probe](#permission-probe) (`probe.permission.*`), raises a real system prompt on demand.

## Touch probe

A direct physical input receipt says Manzanero dispatched a touch; it does not say iOS delivered it. Before the probe, delivery was judged from screenshots of Settings and Maps: some taps returned success with no visible effect, three-to-five-contact gestures were never shown to arrive as that many contacts, and hold duration and release were unverified.

The touch probe records every touch UIKit delivers to the app and lets Manzanero read that record back. The [touch measurement runner](probe-touch-runner.md) (`mise run test:probe-touch <UDID>`) sends known touches and compares them with what the app received: delivery rate, coordinate error, contact count, hold duration and release. It has run on the iPhone 13 mini, where it found and measured the fix for lost short gestures, and on iPhone and iPad simulators ([verification](verification.md#touch-delivery-measured-with-the-probe-app)).

The app is a test fixture. It is not part of the `manzanero` product and has no third-party dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `Fixtures/ProbeApp/Project.swift`, `Tuist.swift` | Tuist manifests (local generation only) |
| `Fixtures/ProbeApp/Config/ProbeApp.xcconfig` | Neutral bundle identifier and signing defaults, with an optional untracked include |
| `Fixtures/ProbeApp/ProbeCore/` | UIKit-independent Swift package: recorder, readout formats (summary, last gesture, recent gestures) and log format (encoding and decoding), log writer, the log probe's plan (`LogProbe`), Swift Testing tests; also the host-only [measurement runner](probe-touch-runner.md) targets, which the app does not link |
| `Fixtures/ProbeApp/App/` | UIKit app: scene setup, touch surface, accessibility elements, drawing, log probe emitter, text probe, permission probe |
| `Fixtures/ProbeApp/UITests/` | XCUITest checks of the recording path in the simulator |

Requirements: iOS 18.0 or later, iPhone or iPad (full screen through `UIRequiresFullScreen`; Xcode 27.2's test runs warn that the key "will soon be ignored", so a later iPadOS may window the probe). Portrait only, unless launched with the argument `-ProbeAllowRotation YES` (for example `xcrun simctl launch <UUID> <bundle-id> -ProbeAllowRotation YES`), which lets the interface follow the device into landscape for rotation measurements; positions stay normalized to the current interface. Swift 6 language mode with complete strict concurrency. Built and tested with Xcode 27.2 and Tuist 4.214.0.

## Generate, test and build

```sh
mise run probe-app:test       # core and measurement-runner tests on macOS through xcsift; no simulator
mise run probe-app:generate   # Tuist workspace at tmp/probe-app/generated/
```

Tuist always writes the project, workspace and `Derived/` next to the manifest it loads and has no output-directory option. So the generate task copies `Project.swift` and `Tuist.swift` into `tmp/probe-app/generated/` and generates there. It sets `TUIST_PROBE_APP_FIXTURE` so the copied manifest points back at the tracked sources in `Fixtures/ProbeApp/`. Nothing generated lands in the tracked tree, and no `.gitignore` change is needed. Do not run `tuist generate` inside `Fixtures/ProbeApp/` itself: it would work, but it writes untracked projects there. The task pins Tuist through mise and does not use a Tuist account, server or binary cache.

Build for a simulator (the simulator must exist; building does not boot it):

```sh
xcodebuild -workspace tmp/probe-app/generated/ProbeApp.xcworkspace -scheme ProbeApp \
  -destination 'platform=iOS Simulator,id=<simulator-UUID>' \
  -derivedDataPath tmp/probe-app/DerivedData build 2>&1 | xcsift -f toon --warnings
```

Replace `build` with `test` to run the XCUITest target on a booted simulator. Then install and launch with `xcrun simctl install <simulator-UUID> <path>/ProbeApp.app` and `xcrun simctl launch <simulator-UUID> com.lemambo.manzanero.probeapp`. Or use Manzanero's Build & Run, which takes the generated workspace:

```sh
manzanero build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --simulator <simulator-UUID>
```

Xcode's package resolution can create an ignored `Fixtures/ProbeApp/ProbeCore/.swiftpm/`.

## Signing for a physical device

The tracked files hold no team identifier. The default bundle identifier is the project's `com.lemambo.manzanero.probeapp`; another team must replace it with one it can sign. Put your values in the untracked `.env.local` at the repository root, which mise loads for every task:

```sh
DEVELOPMENT_TEAM=<team-id>
DEVELOPER_DIR=/path/to/Xcode-27.2.app/Contents/Developer
# PROBE_APP_BUNDLE_ID=<your.bundle.id>   only if you cannot sign the default
```

`DEVELOPER_DIR` selects Xcode 27.2 for the tasks without changing the system-wide `xcode-select` choice; `Tuist.swift` refuses to generate with any other Xcode version. Then run `mise run probe-app:generate`. Alternatively, pass the variables on the command line, or write the untracked `tmp/probe-app/Signing.xcconfig` yourself:

```
DEVELOPMENT_TEAM = <team-id>
PROBE_APP_BUNDLE_ID = <your.bundle.id>
```

`Config/ProbeApp.xcconfig` includes that file optionally (`#include?`). The manifest sets the app target's bundle identifier to `$(PROBE_APP_BUNDLE_ID)` because Tuist writes its `bundleId` into the target's build settings, which would otherwise override any xcconfig value. Signing is automatic. The task validates the formats, overwrites the file when either variable is set, and leaves it alone when neither is set.

By default Build & Run signs only with profiles already on the Mac. From a clean state (no profile for the bundle identifier, phone not yet registered with the team), let Xcode create what is missing. Xcode must have an account for the team under Xcode > Settings > Accounts, and the phone must be connected, unlocked, trusted and in Developer Mode:

```sh
manzanero build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --device <UDID> \
  --allow-provisioning-updates --allow-device-registration --dry-run    # check the plan first
manzanero build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --device <UDID> \
  --allow-provisioning-updates --allow-device-registration
```

These options let Xcode use your developer account: it may create a development certificate, register the bundle identifier, create or update a development profile, and add the phone to the team's device list. Leave out `--allow-device-registration` if the phone is already registered, and both options once a profile that includes the phone exists. Use the hardware UDID (`00008…-…`) for `<UDID>`; a CoreDevice UUID also works but costs an extra device query. If signing fails, the error names the likely cause after the raw log path. See [Build & Run](build-run.md#signing-and-provisioning-physical-only).

On the iPhone 13 mini this signed, installed and launched the app once the phone was registered with the team; a later build without the options reused the profile ([Build & Run](build-run.md#verification-and-limits)).

## Capture

The root view is one full-screen UIKit view with `isMultipleTouchEnabled` and no gesture recognizers. It records every `UITouch` in `touchesBegan`, `touchesMoved`, `touchesEnded` and `touchesCancelled`. Raw callbacks are used instead of SwiftUI gestures because the probe needs per-contact events, not recognised gestures.

To reduce system interference, the view controller:

- hides the status bar (also at launch);
- auto-hides the home indicator;
- defers system edge gestures on all edges, so the first edge swipe reaches the probe;
- locks the interface to portrait;
- disables the idle timer while active, keeping the display awake for Manzanero's input and AX paths.

These are requests UIKit may limit. Control Center, Notification Center, the home gesture and system alerts can still take touches. Those touches appear as `cancelled` or are missing from the log.

Coalesced and predicted touches are not recorded. A `moved` event is the main touch of each callback, roughly one per display frame per contact. Several touches in one callback are recorded one after another, ordered by `timestamp`.

## Record format: `Documents/touch-log.jsonl`

One compact JSON object per line, sorted keys. All three line types carry `type` and `session`.

Session header, always the first line:

```json
{"reason":"launch","scale":3,"session":"abcad94d5fd67237","size":[390,844],"started":"2026-11-15T09:41:21Z","type":"session","uptime":433754.360671,"v":1}
```

| Field | Meaning |
| --- | --- |
| `session` | 16 lowercase hex characters, random per session |
| `reason` | `launch` or `reset` |
| `started` | Wall-clock start (ISO 8601, UTC); informational |
| `uptime` | `ProcessInfo.systemUptime` at session start, seconds |
| `size` | Interface size in points, `[width, height]` |
| `scale` | Screen scale, pixels per point |
| `v` | Format version, currently 1 |

Touch event, one per contact per callback:

```json
{"active":2,"contact":1,"kind":"direct","nx":0.5,"ny":0.99408,"phase":"began","radius":22.79,"seq":2,"session":"f3cebbed89520c56","t":433566.56084,"type":"event","x":195,"y":839}
```

| Field | Meaning |
| --- | --- |
| `seq` | 1-based, increases by one per event within a session |
| `contact` | 0-based index assigned at `began`, stable until that contact ends or is cancelled; never reused within a session |
| `phase` | `began`, `moved`, `ended` or `cancelled` |
| `x`, `y` | Position in points, origin top left of the window (two decimals) |
| `nx`, `ny` | Position normalised 0...1 in the current interface, origin top left (five decimals). This is the space Manzanero's `tap x y` uses. Not clamped. |
| `t` | `UITouch.timestamp` (six decimals) |
| `active` | Contacts down at this event, including the contact it describes. An `ended` or `cancelled` contact is counted on its own final event. |
| `kind` | `UITouch.TouchType`: `direct`, `indirect`, `pencil`, `indirectPointer` or `unknown` |
| `radius` | `UITouch.majorRadius` in points, as UIKit reports it |

**Timestamps are device uptime in seconds.** Only differences between them are meaningful. They are not wall-clock times and cannot be compared directly with host clocks. `uptime` in the header comes from the same kind of clock, so it relates events to the session start only approximately.

Truncation marker, written once as the final line when the log reaches its limit:

```json
{"firstDroppedSeq":20412,"limitBytes":4194304,"session":"abcad94d5fd67237","type":"truncated"}
```

### Bounds and durability

- Each session has a 4 MiB limit, roughly 20,000 events. When the next event would exceed it, that event and all later events in the session are dropped and counted, and the truncation marker is written in 256 bytes kept free for it. The start of a session is always intact, which suits a run that resets and then measures.
- A launch or reset replaces the file. **Pull the log before relaunching or resetting.**
- Lines are buffered in memory. They are written when no contacts remain down (so a completed gesture is on disk), when 64 KiB are buffered, on reset, and when the scene resigns active or enters the background. A pull taken while a contact is held can miss that gesture's recent events.
- A write error is reported in the summary's `log.error`. The counters describe what the probe tried to write.

## Readback path 1: accessibility

The surface view is an accessibility container. Its children are four `UIAccessibilityElement` objects, not views, so they cannot intercept touches. Their frames do not overlap.

| Identifier | Label | Value | Frame (points, container space) |
| --- | --- | --- | --- |
| `probe.touch.summary` | `Probe summary` | Summary JSON (below) | x 16, y 64, width − 32, height 92 |
| `probe.touch.last-gesture` | `Probe last gesture` | Last completed gesture JSON (below) | x 16, y 164, width − 32, height 120 |
| `probe.touch.recent-gestures` | `Probe recent gestures` | Recent completed gestures JSON (below) | x 16, y 292, width − 32, height 92 |
| `probe.touch.reset` | `Reset probe` | Current session identifier; button trait; resets when activated | 180×52 box, bottom centre, 132 above the bottom edge |

The three readouts carry the `staticText` and `updatesFrequently` traits.

**Why the value carries the JSON.** Manzanero's physical tree (`AccessibilitySnapshot.normalize`) returns `label`, `hint`, `identifier`, `value`, `frame`, `traits` and `visible` for each node, plus `nativeAttributes` (string metadata from native attributes `5003`, `5004` and `3003`) when present. Each text field is returned verbatim as a string scalar, with no per-string length cap. The bounds are 512 nodes, depth 32, a 16 MiB archive limit and a 40 MiB per-session callback budget. The summary and last-gesture readouts are a few hundred bytes to about 1.5 KB; the recent-gestures readout is bounded at about 8.2 KB (below). `identifier` is the stable selector. `label` stays a short fixed name, because `press --label` matches on it exactly and VoiceOver speaks it. `accessibilityValue` is the property meant for changing content. Values are computed when they are queried, so every snapshot reads current state.

```sh
manzanero tree --device <UDID>
```

Find the nodes whose `identifier` is `probe.touch.summary`, `probe.touch.last-gesture` or `probe.touch.recent-gestures` and parse their `value` as JSON. The physical tree route requires the probe to be the foreground app at the display centre and the device in native portrait orientation (`rot0`). The probe stays in portrait unless launched with `-ProbeAllowRotation YES`.

The probe's identifiers say which elements to read, not which app owns them. On one phone and iOS version, a node's `nativeAttributes["3003"]` carried the owning app's bundle identifier (`com.apple.Preferences` for Settings). The [measurement runner](probe-touch-runner.md#foreground-identity) compares it with the bundle identifier it pulls from when the attribute is present. That rests on one observation, so its absence is reported as "not checked", not as a failure. The probe app itself does nothing to set it.

Summary (`probe.touch.summary`; illustrative values):

```json
{"active":0,"began":2,"cancelled":0,"ended":2,"events":4,"gestures":1,"log":{"bytes":748,"dropped":0,"lines":5},"maxActive":2,"moved":0,"session":"f3cebbed89520c56","size":[390,844],"unmatched":0,"v":1}
```

| Field | Meaning |
| --- | --- |
| `events` | Events recorded, equal to the last `seq` |
| `began`, `moved`, `ended`, `cancelled` | Counts per phase |
| `unmatched` | Moved/ended/cancelled callbacks for a touch this session does not know, such as a contact held across a reset. They get no `seq` and are not logged. |
| `active` | Contacts down now |
| `maxActive` | Most contacts down at once in this session |
| `gestures` | Completed gestures in this session |
| `log` | `lines` (including the header), `bytes`, `dropped`, and `error` when a write failed |

Last completed gesture (`probe.touch.last-gesture`). A gesture runs from a `began` with no contacts down until no contacts remain down:

```json
{"contacts":[{"began":433566.56084,"c":0,"duration":0.066667,"end":"ended","from":[0.5,0.00592],"moves":0,"to":[0.5,0.00592]},{"began":433566.56084,"c":1,"duration":0.066667,"end":"ended","from":[0.5,0.99408],"moves":0,"to":[0.5,0.99408]}],"duration":0.066667,"gesture":1,"maxActive":2,"session":"f3cebbed89520c56","v":1}
```

| Field | Meaning |
| --- | --- |
| `gesture` | 1-based number in the session; 0 and empty `contacts` when none has completed |
| `maxActive` | Most contacts down at once during the gesture |
| `duration` | First `began` to last `ended`/`cancelled`, seconds |
| `contacts[].c` | Contact index, in ascending order |
| `contacts[].from`, `to` | Normalised `[x, y]` at `began` and at `ended`/`cancelled` |
| `contacts[].began` | `UITouch.timestamp` of `began` |
| `contacts[].duration` | `began` to `ended` (or `cancelled`), seconds |
| `contacts[].end` | `ended` or `cancelled` |
| `contacts[].moves` | Number of `moved` events |

Recent completed gestures (`probe.touch.recent-gestures`), oldest first:

```json
{"dropped":0,"gestures":2,"limit":32,"recent":[{"contacts":[{"began":433560.11,"c":0,"duration":0.08,"end":"ended","from":[0.3,0.5],"moves":0,"to":[0.3,0.5]}],"duration":0.08,"gesture":1,"maxActive":1},{"contacts":[{"began":433566.56084,"c":1,"duration":0.066667,"end":"ended","from":[0.5,0.00592],"moves":0,"to":[0.5,0.00592]},{"began":433566.56084,"c":2,"duration":0.066667,"end":"ended","from":[0.5,0.99408],"moves":0,"to":[0.5,0.99408]}],"duration":0.066667,"gesture":2,"maxActive":2}],"session":"f3cebbed89520c56","v":1}
```

| Field | Meaning |
| --- | --- |
| `gestures` | Completed gestures in this session; equals the summary's `gestures` |
| `dropped` | Completed gestures of this session no longer listed (always the oldest) |
| `limit` | Most entries kept (32) |
| `recent[]` | One entry per completed gesture, oldest first: `gesture`, `maxActive`, `duration` and `contacts`, with the same meaning as in the last-gesture readout (no per-entry `v` or `session`) |

Invariants: `dropped + recent.count == gestures`, and the entries are numbered `dropped + 1 … gestures` without gaps. The last entry is the gesture in `probe.touch.last-gesture`. A gesture still in progress is not listed. A reset or relaunch empties the list and sets `dropped` to 0 in the new session.

**Bound and overflow.** At most 32 entries, and at most 8192 bytes of compact JSON for the entries together (the commas between them included). When a gesture completes and either bound would be exceeded, the oldest entries are removed one at a time until both hold, and each removal adds one to `dropped`. The newest gesture is always kept, even if it alone is larger than 8192 bytes; that needs dozens of contacts in one gesture, and the last-gesture readout has never been bounded either. The fixed fields add at most about 120 bytes. Measured sizes:

- a one-contact tap entry: 150 bytes;
- a pessimistic five-contact entry (seven-digit uptime, five-decimal positions, moves, cancelled contacts): 706 bytes, so 11 of them fit (7,742 bytes for the whole value);
- the runner's whole built-in plan (15 gestures, 29 contacts): 3,815 bytes, so one readback after the plan lists every gesture.

The bound comes from the device side, not Manzanero's. Manzanero does not cap string length, and 8 KB is about 0.05 % of its 16 MiB archive limit. How large an accessibility value iOS will carry through the remote snapshot is not documented and has not been measured, and an oversized value could break the whole `tree` read rather than only this element. So the readout is kept within a few times the size of the readouts that already exist (about 1.5 KB), while still covering a multi-gesture action, a run's shared readback window, or the built-in plan with `--readback end`. Whether a value of this size actually crosses on a phone has not been checked.

Compare the `session` with the value read before sending input. If it changed, the app was relaunched or reset, and the readout does not describe that input.

## Text probe

One editable `UITextField` and a readout of exactly what it holds, to check text entry (HID `type`, `key`, and `set-value`) code point for code point. Source: `Fixtures/ProbeApp/App/ProbeTextProbe.swift`.

| Identifier | Label | Value | Frame |
| --- | --- | --- | --- |
| `probe.text.field` | `Probe text field` | The field's text (the placeholder `text probe` while empty); a text field, so its value is settable | Portrait: full width minus 16-point margins, 40 high, 100 points above the reset box. Landscape: 200 × 40 at the top right, 16 points from the edges |
| `probe.text.value` | `Probe text value` | `{"edits":…,"focused":…,"scalars":…,"text":…,"utf8":…,"v":1}`, keys sorted: the text, its UTF-8 byte and Unicode scalar counts, the number of changes the field reported, and whether it is first responder | Portrait: a 20-point strip just below the field. Landscape: 200 × 20 to the field's left |

The field has an empty input view, so no on-screen keyboard appears and covers it; hardware keyboard events (Manzanero's HID typing) still reach it. It is a subview of the touch surface: touches inside its frame go to the field and are not recorded by the touch probe. On a 390 × 844 screen it spans y 0.725...0.773, below every point of the built-in touch plan (y at most 0.65); in landscape it lies above them (y below 0.15 on an iPhone). Lower in a landscape screen, where it overlapped the recent-gestures readout's area, it reported itself not visible to accessibility, which is why it moves. The touch probe's readouts, log and formats are unchanged; the tree simply has two more elements.

## Readback path 2: file

```sh
manzanero files pull <bundle-id> Documents/touch-log.jsonl tmp/touch-log.jsonl --device <UDID>
```

`<bundle-id>` is the identifier the app was signed with. This uses Apple's `devicectl device copy from` on the app data container. The app also sets `UIFileSharingEnabled`. In the simulator the same file is at `$(xcrun simctl get_app_container <simulator-UUID> <bundle-id> data)/Documents/touch-log.jsonl`.

## Reset without touching the surface

Activating `probe.touch.reset` through accessibility clears the counters, the marks and the log, and starts a new session whose header has `reason: reset`. Manzanero does this with an exact-identifier press:

```sh
manzanero press --id probe.touch.reset --device <UDID>
```

The element meets `press`'s guards by construction. It has a fixed unique identifier, a positive frame wholly inside the display (a 180×52-point box near the bottom centre, outlined on screen), enabled and visible state, and no overlapping element, so an AX hit test at its centre should resolve to it. `accessibilityActivate()` performs the reset and returns `true`, which tells UIKit not to fall back to a synthesized tap. If a press were ever delivered as a tap instead, it would show as a `began`/`ended` pair at the reset box in the new session. A touch on the reset box is recorded like any other touch and does not reset.

A fresh launch always starts a new session. The model is owned by the application delegate, so a scene reconnect within one process does not.

## Display

The screen shows the session identifier, the running counts, the last gesture's contacts and the newest four recent gestures (number, contacts, `maxActive`, duration) with the listed and dropped counts as text. Each landing is a ring with a cross and its contact index, colour-coded per contact; the last 40 are kept. Contacts that are down show as filled discs. This is for a person reading a screenshot. The JSON readouts are authoritative.

## What the probe can and cannot show

Can show:

- whether a dispatched touch reached this app's UIKit view, and with what phases;
- the position UIKit reported, in points and normalised, for comparison with the requested coordinates;
- how many contacts UIKit considered down at once, and whether each ended or was cancelled;
- hold duration between `began` and `ended` timestamps, as UIKit stamped them.

Cannot show:

- delivery to other apps, system UI or gesture recognisers; the probe has none of its own;
- hardware or digitizer timing. Timestamps are UIKit's, after any system processing, and the probe cannot tell transport latency apart from UIKit delivery;
- whether a missing touch was dropped by Manzanero, by the transport or by iOS. Only that it did not arrive here;
- coalesced sub-frame samples, which are not recorded;
- behaviour in Split View or a windowed iPad app: the probe requires full screen. Landscape needs `-ProbeAllowRotation YES`; it was measured on simulators, not on a phone.

## Log probe

The log probe writes known lines so that [`logs`, `console` and `last-crash`](app-logs.md) can be checked against ground truth. Its plan is `LogProbe` in ProbeCore (UIKit-free, unit-tested); `App/LogProbeEmitter.swift` writes it. It shares nothing with the touch probe's state.

**One set** of lines, each carrying a token and the set's number `#n` (1 for the launch set, counting up per process):

| Where | Text |
| --- | --- |
| `Logger(subsystem: <bundle id>, category: "probe")` at debug, info, notice, error and fault, `privacy: .public` | `probe.log <token> #<n> level=<debug\|info\|default\|error\|fault>` (notice is the log's `default`) |
| The same logger at notice, with a `.private` interpolation | `probe.log <token> #<n> private=` followed by `secret-<token>` as the private value |
| stdout, then `fflush(stdout)` | `stdout <token> #<n> flushed` |
| stdout, not flushed | `stdout <token> #<n> unflushed` |
| `FileHandle.standardError` | `stderr <token> #<n>` |

**Triggers**, none of which needs a touch:

- Every launch writes one set. The token is the value after the launch argument `-probeLogToken` (1...64 ASCII letters, digits, `.`, `_`, `-`), else `launch`.
- Activating the accessibility element `probe.log.emit` writes another set with the token `emit`: `manzanero press --id probe.log.emit (--device <UDID> | --simulator <UUID>)`. The element is a button-trait `UIAccessibilityElement` (label `Emit probe logs`, value `{"sets":N}`), added to the touch surface's accessibility elements at x 16, y 400, 180×52 points, clear of the touch probe's elements. It is not a view, so it never receives touches. A custom URL scheme was tried first and dropped: iOS asks "Open in “Probe”?" before delivering it, which needs a touch.
- `-probeCrash abort|trap` crashes deliberately one second after the launch set, after logging `probe.log <token> about to crash mode=<mode>` at error and printing it to stdout with a flush (which also flushes the unflushed line). `abort` calls `abort()` (SIGABRT); `trap` calls `fatalError` (SIGTRAP). Only that launch argument crashes the app; nothing in the measurement runner or the UI passes it.

```sh
manzanero console com.lemambo.manzanero.probeapp --seconds 5 --os-log --simulator <UUID> -- -probeLogToken T1
manzanero logs --seconds 10 --bundle com.lemambo.manzanero.probeapp --level debug --simulator <UUID>   # press --id probe.log.emit meanwhile
manzanero console com.lemambo.manzanero.probeapp --seconds 6 --simulator <UUID> -- -probeLogToken K1 -probeCrash abort
manzanero last-crash --bundle com.lemambo.manzanero.probeapp --since <ISO-8601 before the launch> --simulator <UUID>
```

Results on one iPhone Air simulator are in [verification](verification.md#app-logs-console-and-crashes).

## Permission probe

The permission probe raises a genuine system prompt when asked, so that [handoff](handoff.md) and prompt handling can be checked against something a person has to decide. Its plan is `PermissionProbe` in ProbeCore (unit-tested); `App/PermissionProbeRequester.swift` drives it. It shares nothing with the other probes and posts no notification.

| Identifier | Label | Value | Frame |
| --- | --- | --- | --- |
| `probe.permission.request` | `Request notification permission` | `{"requests":N,"status":…,"v":1}`, keys sorted: requests made by this process, and the app's notification authorization (`unknown` until first read, `notDetermined`, `denied`, `authorized`, `provisional`, `ephemeral`) | x 204, y 400, 155×52 points, to the right of `probe.log.emit`; a button-trait accessibility element, not a view |

Activating it (`manzanero press --id probe.permission.request (--device <UDID> | --simulator <UUID>)`) calls `requestAuthorization(options: [.alert])`. Notification permission was chosen because it needs no usage string and no entitlement. The system shows its prompt only while the status is `notDetermined`; after a decision a request changes nothing, and getting the prompt again means uninstalling the app and installing it once more. The status is read again when the app becomes active, so a change made in Settings shows up.

On the iPhone 13 mini on 2026-11-17 the press raised "Probe quiere enviarte notificaciones", which the tree read with both buttons, and after the owner's choice the value read `denied` ([verification](verification.md#handoff-with-an-app-permission-prompt)). On an iPhone 17e simulator the same press raised "“Probe” Would Like to Send You Notifications" a few seconds later, and `press --label Allow` from a second process answered it while a handoff watched ([verification](verification.md#handoff-watch-a-timeout-on-the-phone-and-runs-on-a-simulator)).

## List probe

Launched with `-ProbeList YES`, the iOS probe shows two lists in place of the touch surface (`App/ProbeListViewController.swift`): a table of sixty rows and, above it, a strip of forty columns that moves sideways. Both keep only the cells near the screen, so a row further on has no accessibility element until its list has moved, which is what [`scroll --search`](direct-accessibility.md#searching-a-list-that-loads-its-rows---search) is for.

| Identifier | Element | Notes |
| --- | --- | --- |
| `probe.list.row.1` … `probe.list.row.60` | The table's rows, labelled "Row 1" … "Row 60" | Plain `UITableView` cells. Selecting one records `row-<n>` |
| `probe.list.col.1` … `probe.list.col.40` | The strip's columns, labelled "Col 1" … "Col 40" | Collection view cells with the button trait. Selecting one records `col-<n>` |
| `probe.list.last` | A label, "Last: none" at launch | Its value is the last row or column selected |

```sh
xcrun simctl launch <simulator-UUID> com.lemambo.manzanero.probeapp -ProbeList YES
manzanero scroll --id probe.list.row.55 --search 80 --simulator <simulator-UUID>
manzanero scroll --id probe.list.col.3 --search 80 --toward left --simulator <simulator-UUID>
manzanero press --id probe.list.row.55 --simulator <simulator-UUID>
manzanero wait --id probe.list.last --until value --value row-55 --simulator <simulator-UUID>
```

The touch, log and permission probes are not on this screen. Run on one iPhone simulator ([record](verification.md#a-search-on-an-iphone-simulator-and-a-table-rows-two-objects)); not on a phone, where the app would have to be launched with the argument by other means than `manzanero launch`.

## tvOS probe

A second, separate app in the same Tuist project: target and scheme `ProbeTV`, sources in `Fixtures/ProbeApp/TV/`, bundle identifier `com.lemambo.manzanero.probetv` (`Config/ProbeTV.xcconfig`; `PROBE_TV_BUNDLE_ID` in the untracked signing file replaces it), tvOS 18.0 or later. It shares nothing with the iOS probe and does not use ProbeCore. It answers one question: which Siri Remote command did the app receive?

| Identifier | Element | Reads as |
| --- | --- | --- |
| `probe.tv.button.a`, `.b`, `.c` | Three buttons in a row | Selecting one records `select:a` (or `b`, `c`) |
| `probe.tv.twin.1`, `probe.tv.twin.2` | Two buttons that share the label `Twin`, to choose between with `--index` | Selecting one records `select:twin-1` or `select:twin-2` |
| `probe.tv.row.1` … `probe.tv.row.40` | A list of forty rows beside the controls, more than fit on screen | Selecting one records `select:row-<n>` |
| `probe.tv.text.field` | A text field | |
| `probe.tv.text.value` | The field's text | value |
| `probe.tv.col.1` … `probe.tv.col.30` | A strip of thirty columns along the bottom, which moves sideways | Selecting one records `select:col-<n>` |
| `probe.tv.hold` | A focusable `Hold` label | A press of select held a second or longer records `select-long`; a short press records nothing |
| `probe.tv.last` | The last command received | value: `up`, `down`, `left`, `right`, `select:<button>`, `select-long`, `menu`, `play-pause`, or `none` |
| `probe.tv.count` | How many commands arrived | value |
| `probe.tv.summary` | A count per kind | value: `up=1 down=0 left=0 right=0 select=0 select-long=0 menu=0 play-pause=0` |

Arrows are recorded through `onMoveCommand`, so one arrives only when focus could not move further in that direction inside the app, as SwiftUI reports it. Menu is recorded and kept (`onExitCommand`), so it does not leave the app: leave with the Home button. Each command also goes to the unified log, category `remote`.

```sh
mise run probe-app:generate
xcodebuild build -workspace tmp/probe-app/generated/ProbeApp.xcworkspace -scheme ProbeTV \
  -destination 'generic/platform=tvOS Simulator' -derivedDataPath tmp/probe-app/DerivedData 2>&1 | xcsift -f toon --warnings
manzanero install tmp/probe-app/DerivedData/Build/Products/Debug-appletvsimulator/ProbeTV.app --simulator <UUID>
manzanero launch com.lemambo.manzanero.probetv --simulator <UUID>
```

`build-run` does not build for tvOS. A build for a physical Apple TV needs a tvOS development profile for the bundle identifier; without one already on the Mac, `xcodebuild` asks for `-allowProvisioningUpdates`, which acts on the Apple developer account and is the owner's decision.

Checked on one tvOS 27.2 simulator on 2026-11-18: each of the seven `remote` buttons was recorded once, and the keys Space, Escape and Return were recorded as `play-pause`, `menu` and `select`. The same day the owner ran it from Xcode onto an Apple TV 4K (3rd generation, tvOS 27.2), where it recorded `play-pause`, `select:b`, `menu`, `up`, `left` twice and `right` as `remote` sent them, and its text field took `set-value` ([record](verification.md#first-look-at-a-physical-apple-tv)). The app starts with focus on the text field, so move up to the buttons before `select`.

## Verification status

The records below are dated; those before 2026-11-16 spell commands in the earlier grammar (`simulator <UUID> build-run`, `press-id`).

Verified on 2026-11-15 with Xcode 27.2 (27B52), Tuist 4.214.0 and an iPhone 17e simulator running iOS 27.2 (24B8117):

- 22 core unit tests passed through xcsift (`mise run probe-app:test`).
- The Tuist workspace generated, and a clean simulator build reported zero errors and zero warnings.
- The app installed and launched with `xcrun simctl`, and a screenshot showed the empty probe with the status bar hidden. The session header was present in `Documents/touch-log.jsonl`.
- Four XCUITest tests passed: an empty launch with all three elements and a new session after relaunch; a single tap recorded within 0.02 of its normalised position; a 1.5-second press measured within 0.4 s; and a two-finger tap reported as `maxActive: 2` with contacts 0 and 1. XCUITest synthesises these touches, so they exercise UIKit delivery and the accessibility readback, not Manzanero's physical input path.
- `manzanero simulator <UUID> build-run` on the generated workspace built, installed and launched the app (`status: launched`). A physical `build-run --dry-run` produced the expected plan.

Later the same day the package gained `Decodable` conformances for these formats (the encoded JSON is unchanged) and the measurement runner; `mise run probe-app:test` then passed 66 tests. See [the runner's verification](probe-touch-runner.md#what-has-and-has-not-been-verified).

The recent-gestures readout was added afterwards and checked with the same tools (Xcode 27.2, Tuist 4.214.0, iPhone 17e simulator, iOS 27.2):

- `mise run probe-app:test` passed 93 tests with zero warnings, 8 of them for the readout: ordering, consistency with the last gesture, the count bound, the byte bound with five-contact gestures, the newest gesture kept above the byte bound, reset and session change, multi-contact entries, and the JSON shape and decoding.
- A clean simulator build of the app and the UI-test target (`build-for-testing`) reported zero errors and zero warnings.
- Five XCUITest tests passed, including a new one: after two taps, `probe.touch.recent-gestures` lists gestures 1 and 2 at their positions with `dropped: 0`, and its newest entry matches `probe.touch.last-gesture`.

Later the same day Manzanero gained [simulator input and accessibility](simulator-input.md), and the same iPhone 17e simulator gave the first Manzanero-driven readings: `simulator <UUID> tree` returned all four probe elements with their JSON values and `nativeAttributes["3003"]` equal to the probe's bundle identifier; `press-id probe.touch.reset` started a new session without recording a touch; and the [measurement runner](probe-touch-runner.md#what-has-and-has-not-been-verified) measured single-contact delivery through the readouts. These are simulator results; they say nothing about a phone.

On an iPhone 13 mini (iOS 27.2.1), 2026-11-15/16: signing and installation through `build-run`, `tree` readback of all three readouts, `nativeAttributes["3003"]` carrying the probe's bundle identifier, `press-id probe.touch.reset` (which starts a new session without recording a touch), `pull` of the log, and the delivery measurements in [verification](verification.md#touch-delivery-measured-with-the-probe-app). Not verified: a recent-gestures value near its 8 KB bound on a phone, other devices and iOS versions, and landscape.
