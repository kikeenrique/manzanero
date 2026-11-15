# Probe fixture app

The probe app is a small iOS app of this project's own that reports what the device actually received, so Manzanero's operations can be checked against ground truth instead of screenshots. It is meant to hold several probes. The first, and so far the only one, is the touch probe described here; its accessibility identifiers are namespaced `probe.touch.*` so later probes can add their own.

## Touch probe

A direct physical input receipt says Manzanero dispatched a touch; it does not say iOS delivered it. Until now delivery was judged from screenshots of Settings and Maps. Some taps returned success with no visible effect, three-to-five-contact gestures were never shown to arrive as that many contacts, and hold duration and release were unverified.

The touch probe records every touch UIKit delivers to the app and lets Manzanero read that record back. The [touch measurement runner](probe-touch-runner.md) (`mise run test:probe-touch <UDID>`) sends known touches and compares them with what the app received: delivery rate, coordinate error, contact count, hold duration and release. It has been tested offline only; no live run has happened yet.

The app is a test fixture. It is not part of the `manzanero` product and has no third-party dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `Fixtures/ProbeApp/Project.swift`, `Tuist.swift` | Tuist manifests (local generation only) |
| `Fixtures/ProbeApp/Config/ProbeApp.xcconfig` | Neutral bundle identifier and signing defaults, with an optional untracked include |
| `Fixtures/ProbeApp/ProbeCore/` | UIKit-independent Swift package: recorder, readout and log formats (encoding and decoding), log writer, Swift Testing tests; also the host-only [measurement runner](probe-touch-runner.md) targets, which the app does not link |
| `Fixtures/ProbeApp/App/` | UIKit app: scene setup, touch surface, accessibility elements, drawing |
| `Fixtures/ProbeApp/UITests/` | XCUITest checks of the recording path in the simulator |

Requirements: iOS 18.0 or later, iPhone only, portrait only. Swift 6 language mode with complete strict concurrency. Built and tested with Xcode 27.2 and Tuist 4.214.0.

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
manzanero simulator <simulator-UUID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp
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
manzanero --dry-run physical <UDID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp \
  --allow-provisioning-updates --allow-device-registration    # check the plan first
manzanero physical <UDID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp \
  --allow-provisioning-updates --allow-device-registration
```

These options let Xcode use your developer account: it may create a development certificate, register the bundle identifier, create or update a development profile, and add the phone to the team's device list. Leave out `--allow-device-registration` if the phone is already registered, and both options once a profile that includes the phone exists. Use the hardware UDID (`00008…-…`) for `<UDID>`; a CoreDevice UUID also works but costs an extra device query. If signing fails, the error names the likely cause after the raw log path. See [Build & Run](build-run.md#signing-and-provisioning-physical-only).

Physical signing and deployment of this app have not been tried.

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

The surface view is an accessibility container. Its children are three `UIAccessibilityElement` objects, not views, so they cannot intercept touches. Their frames do not overlap.

| Identifier | Label | Value |
| --- | --- | --- |
| `probe.touch.summary` | `Probe summary` | Summary JSON (below) |
| `probe.touch.last-gesture` | `Probe last gesture` | Last completed gesture JSON (below) |
| `probe.touch.reset` | `Reset probe` | Current session identifier; button trait; resets when activated |

**Why the value carries the JSON.** Manzanero's physical tree (`AccessibilitySnapshot.normalize`) returns `label`, `hint`, `identifier`, `value`, `frame`, `traits` and `visible` for each node. Each text field is returned verbatim as a string scalar, with no per-string length cap. The bounds are 512 nodes, depth 32, a 16 MiB archive limit and a 40 MiB per-session callback budget, far above these readouts, which are a few hundred bytes to about 1.5 KB. `identifier` is the stable selector. `label` stays a short fixed name, because `press-label` matches on it exactly and VoiceOver speaks it. `accessibilityValue` is the property meant for changing content. Values are computed when they are queried, so every snapshot reads current state.

```sh
manzanero physical <UDID> tree
```

Find the nodes whose `identifier` is `probe.touch.summary` or `probe.touch.last-gesture` and parse their `value` as JSON. The tree route requires the probe to be the foreground app at the display centre and the device in native portrait orientation (`rot0`). The probe locks portrait.

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

Compare the `session` with the value read before sending input. If it changed, the app was relaunched or reset, and the readout does not describe that input.

## Readback path 2: file

```sh
manzanero physical <UDID> pull <bundle-id> Documents/touch-log.jsonl tmp/touch-log.jsonl
```

`<bundle-id>` is the identifier the app was signed with. This uses Apple's `devicectl device copy from` on the app data container. The app also sets `UIFileSharingEnabled`. In the simulator the same file is at `$(xcrun simctl get_app_container <simulator-UUID> <bundle-id> data)/Documents/touch-log.jsonl`.

## Reset without touching the surface

Activating `probe.touch.reset` through accessibility clears the counters, the marks and the log, and starts a new session whose header has `reason: reset`. Manzanero does this with an exact-identifier press:

```sh
manzanero physical <UDID> press-id probe.touch.reset
```

The element meets `press-id`'s guards by construction. It has a fixed unique identifier, a positive frame wholly inside the display (a 180×52-point box near the bottom centre, outlined on screen), enabled and visible state, and no overlapping element, so an AX hit test at its centre should resolve to it. `accessibilityActivate()` performs the reset and returns `true`, which tells UIKit not to fall back to a synthesized tap. If a press were ever delivered as a tap instead, it would show as a `began`/`ended` pair at the reset box in the new session. A touch on the reset box is recorded like any other touch and does not reset.

A fresh launch always starts a new session. The model is owned by the application delegate, so a scene reconnect within one process does not.

## Display

The screen shows the session identifier, the running counts and the last gesture's contacts as text. Each landing is a ring with a cross and its contact index, colour-coded per contact; the last 40 are kept. Contacts that are down show as filled discs. This is for a person reading a screenshot. The JSON readouts are authoritative.

## What the probe can and cannot show

Can show, once run on hardware:

- whether a dispatched touch reached this app's UIKit view, and with what phases;
- the position UIKit reported, in points and normalised, for comparison with the requested coordinates;
- how many contacts UIKit considered down at once, and whether each ended or was cancelled;
- hold duration between `began` and `ended` timestamps, as UIKit stamped them.

Cannot show:

- delivery to other apps, system UI or gesture recognisers; the probe has none of its own;
- hardware or digitizer timing. Timestamps are UIKit's, after any system processing, and the probe cannot tell transport latency apart from UIKit delivery;
- whether a missing touch was dropped by Manzanero, by the transport or by iOS. Only that it did not arrive here;
- coalesced sub-frame samples, which are not recorded;
- behaviour in landscape or on iPad. The probe is portrait-only and iPhone-only.

## Verification status

Verified on 2026-11-15 with Xcode 27.2 (27B52), Tuist 4.214.0 and an iPhone 17e simulator running iOS 27.2 (24B8117):

- 22 core unit tests passed through xcsift (`mise run probe-app:test`).
- The Tuist workspace generated, and a clean simulator build reported zero errors and zero warnings.
- The app installed and launched with `xcrun simctl`, and a screenshot showed the empty probe with the status bar hidden. The session header was present in `Documents/touch-log.jsonl`.
- Four XCUITest tests passed: an empty launch with all three elements and a new session after relaunch; a single tap recorded within 0.02 of its normalised position; a 1.5-second press measured within 0.4 s; and a two-finger tap reported as `maxActive: 2` with contacts 0 and 1. XCUITest synthesises these touches, so they exercise UIKit delivery and the accessibility readback, not Manzanero's physical input path.
- `manzanero simulator <UUID> build-run` on the generated workspace built, installed and launched the app (`status: launched`). A physical `build-run --dry-run` produced the expected plan.

Later the same day the package gained `Decodable` conformances for these formats (the encoded JSON is unchanged) and the measurement runner; `mise run probe-app:test` then passed 66 tests. See [the runner's verification](probe-touch-runner.md#what-has-and-has-not-been-verified).

Not verified: anything on physical hardware. That includes signing, installation, `tree` readback, `press-id probe.touch.reset`, `pull` of the log, and every delivery measurement. Activating the reset element through accessibility was not exercised in the simulator, because XCUITest has no accessibility-activate action. Manzanero cannot inject touches into a simulator.
