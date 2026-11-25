# Touch measurement runner

The runner sends a known plan of touches through Manzanero's CLI to a physical iPhone, or with `--platform simulator` to a booted simulator, running the [probe app](probe-app.md), reads back what the touch probe recorded, and reports delivery rate, coordinate error, contact counts, hold durations and release. It replaces judging delivery from screenshots.

The comparison and the runner logic pass offline tests against canned `tree` output, receipts and logs built with the probe's own recorder. Live runs: one iPhone 13 mini ([verification](verification.md#touch-delivery-measured-with-the-probe-app)) and one iPhone 17e simulator ([results below](#simulator-runs)).

## Where the code lives

All of it is in the `Fixtures/ProbeApp/ProbeCore` Swift package. None of it is linked into the app, which still depends only on the `ProbeCore` library, or into `manzanero`.

| Target | Contents |
| --- | --- |
| `ProbeCore` | Recorder and formats used by the app; now also `Decodable` for the log lines and readouts (`ProbeRecordDecoding.swift`), with unchanged JSON |
| `ProbeAnalysis` | Plan format and validation, log parser, gesture reconstruction, sent-versus-received comparison, report types. Pure: no clocks, files or processes |
| `ProbeTouchRunner` | Run orchestration, argument parsing, tree and receipt parsing, dry run. Process, file and clock access go through injected protocols |
| `probe-touch` | Command-line front end: `Process` invoker (argument arrays, no shell), local files, system clock |
| `ProbeMeasurementTests` | Swift Testing tests of all of the above |

A host-side executable in the probe package fits better than a test in the main package or a shell script: it reuses the probe's record types, so the comparison reads exactly what the app writes; it keeps fixture code out of the product, as the repository rules ask; and it can be tested without a device by injecting the CLI invocation. The mise task `test:probe-touch` builds and runs it, like the other opt-in device tasks.

## Before a live session

1. Build and install the probe on the phone ([signing](probe-app.md#signing-for-a-physical-device)), then launch it so it is the foreground app.
2. Keep the phone awake, unlocked and in portrait. The probe disables the idle timer while it is active.
3. Build Manzanero (`mise run build`; the task depends on it).
4. Run the dry run first and read the plan.

## Usage

```sh
mise run test:probe-touch <UDID> --dry-run           # plan and exact commands; contacts no device
mise run test:probe-touch <UDID>                      # built-in plan once
mise run test:probe-touch <UDID> --repeat 5           # five rounds for statistics
mise run test:probe-touch <UDID> --plan <plan.json>   # your own plan
mise run test:probe-touch <UDID> --readback end       # readback only before and after the whole plan
```

Other flags: `--settle <seconds>` (pause before each readback, default 0.5), `--out <dir>`, `--no-reset`, `--no-pull`, `--platform physical|simulator` (default physical), `--any-orientation` (accept a landscape probe at preflight). The probe turns with the device by default since 2026-11-25: for the portrait plan keep the device in portrait or launch the probe with `-ProbeAllowRotation NO`; a landscape probe without `--any-orientation` stops at preflight and says so.

Every Manzanero command the runner builds names the operation first and ends with the target: `--device <UDID>`, or with `--platform simulator` (where the device argument must be the simulator's UUID) `--simulator <UUID>`. Manzanero has no simulator app-data pull, so the pull is skipped and the recent-gestures and last-gesture readouts are the evidence. Every action kind of the built-in plan, including the two-to-five-contact ones, runs on a simulator ([results](#simulator-runs)). The pull uses `PROBE_APP_BUNDLE_ID` when it is set (for example in `.env.local`), else the tracked default. The UDID is required; there is no default device.

The executable can also be run directly after `swift build --package-path Fixtures/ProbeApp/ProbeCore --scratch-path tmp/probe-app/core-build --product probe-touch`:

```sh
tmp/probe-app/core-build/debug/probe-touch run <UDID> --dry-run
tmp/probe-app/core-build/debug/probe-touch plan > tmp/my-plan.json   # built-in plan as a starting point
tmp/probe-app/core-build/debug/probe-touch compare tmp/probe-touch/<run>   # rebuild the report offline
```

Exit status: 0 when every action was sent; 3 when the run stopped early (the report is still written for what was sent); 2 for a usage error, an invalid plan or a dry-run command that `manzanero --dry-run` rejects.

### Dry run

`--dry-run` validates the plan, then prints every step with the exact argument vector it would pass to `.build/debug/manzanero`. When that binary exists, it also passes each distinct command to `manzanero --dry-run`, which parses and plans without touching a device, and reports any command the CLI rejects. It writes no files.

## How a run proceeds

1. **Validate the plan** against Manzanero's documented limits ([physical input](native-input.md), [multitouch](multitouch.md), [sequences](gesture-sequences.md)). An invalid plan sends nothing. Points within 0.05 of an edge, or on the probe's reset box, produce warnings.
2. **Preflight readback:** `manzanero tree --device <UDID>`. The tree must contain exactly one `probe.touch.summary` whose value parses as a v1 summary, the [foreground identity](#foreground-identity) must not contradict the expected bundle identifier, the size must be portrait (unless `--any-orientation`), and no contact may be down. Otherwise the run stops before any input. The tree selects the app at the display centre, so a missing summary means the probe is not the foreground app.
3. **Reset:** `manzanero press --id probe.touch.reset --device <UDID>`. This is an accessibility activation, not a touch. The receipt must say `accepted`.
4. **Baseline readback:** the session must have changed, the identity must not be contradicted, and no contact may be down. Events recorded after the reset and before the first action (for example a reset press delivered as a tap) are counted as unattributed and excluded from every window.
5. **For each action:** send `manzanero <command ...> --device <UDID>`, wait the settle time, then read the tree again (`--readback each`, the default). With `--readback end`, only the settle pause separates actions and one readback follows the last.
6. **Closing readback:** if the run stopped for a reason other than a failed readback and the last sent action has no readback, one more tree read (no input) bounds its window.
7. **Pull:** `manzanero files pull <bundle-id> Documents/touch-log.jsonl <run-dir>/touch-log.jsonl --device <UDID>`, unless `--no-pull` or nothing was measured. A pull sends no input, so it also runs after an early stop.
8. **Compare** and write the report.

### Stop rules

No input is ever retried or replayed. The runner stops:

- before any input, if the preflight, reset or baseline check fails;
- after an action, if its readback fails, the probe summary is missing, the summary node reports a different bundle identifier, or a contact is still down (release unverified);
- after three consecutive dispatch failures;
- with `--readback end`, at the first dispatch failure, because there is no foreground check before the next input.

A failed dispatch (non-zero exit, a receipt other than `dispatched`, or a timeout) is recorded, and its readback is still taken: a failure after a down event can leave a partial effect. A probe session that changes between readbacks (reset or relaunch) is recorded, and the run continues as long as the probe is still foreground.

### Foreground identity

The probe's accessibility identifiers say which elements to read, not which app owns them. Each node of Manzanero's physical tree may carry `nativeAttributes`; on one phone and iOS version, attribute `3003` held the owning app's bundle identifier (`com.apple.Preferences` for Settings). Every readback (preflight, baseline, after each action, closing) reads `nativeAttributes["3003"]` of the `probe.touch.summary` node and compares it with the bundle identifier the runner pulls from (`--bundle-id`, `PROBE_APP_BUNDLE_ID`, else the tracked default):

- **present and equal:** `matched`;
- **absent** (no `nativeAttributes`, or no `3003` in it): `not-checked`. The run continues, the runner prints one note, and the report counts it. Because the meaning of `3003` rests on one observation, absence is not treated as failure;
- **present and different:** treated like a missing probe summary. The readback fails, so the run stops before any input (preflight, baseline) or before further input (after an action), and the mismatched readback is not kept. The stop reason names both identifiers. A likely cause besides another app in the foreground is a probe signed with a different bundle identifier than the one the runner pulls from.

Each readback's observed value is kept as `bundleID` in `run.json`, so `probe-touch compare` recomputes the same identity results.

Per-command deadlines are 90 seconds for `tree` and `press`, the action's scheduled duration plus 90 seconds for input, and 180 seconds for `pull`. At a deadline the runner sends SIGINT, which Manzanero turns into cancellation with an attempted release, and SIGTERM 35 seconds later if needed. Interrupting the runner itself (Ctrl-C) also signals the Manzanero child in the same process group; `run.json` is rewritten after every step, so evidence up to the interruption remains, and `probe-touch compare` can rebuild a report from it.

### Device state left

The runner launches, terminates and relaunches nothing and presses no button. Unless `--no-reset` is given, it resets the probe once; afterwards the probe's current session and `Documents/touch-log.jsonl` hold the run's touches until the next reset or launch. The probe stays in the foreground with its idle timer disabled. If a contact was still down at the last readback, the summary says release is unverified; inspect the device before anything else.

## Plan format

```json
{
  "v": 1,
  "name": "my-plan",
  "settleSeconds": 0.5,
  "positionTolerance": 0.03,
  "durationTolerance": 0.15,
  "actions": [
    {"id": "tap", "kind": "tap", "x": 0.5, "y": 0.45},
    {"id": "hold", "kind": "long-press", "x": 0.5, "y": 0.5, "seconds": 0.8},
    {"id": "up", "kind": "swipe", "from": [0.5, 0.65], "to": [0.5, 0.35], "seconds": 0.5},
    {"id": "right", "kind": "drag", "from": [0.3, 0.55], "to": [0.7, 0.55], "seconds": 0.8},
    {"id": "two", "kind": "multi-tap", "points": [[0.35, 0.45], [0.65, 0.45]]},
    {"id": "three-up", "kind": "multi-drag", "seconds": 0.6, "paths": [[0.3, 0.6, 0.3, 0.4], [0.5, 0.6, 0.5, 0.4], [0.7, 0.6, 0.7, 0.4]]},
    {"id": "spread", "kind": "pinch", "center": [0.5, 0.5], "startSpan": 0.2, "endSpan": 0.5, "seconds": 0.6},
    {"id": "double", "kind": "gesture", "frames": [
      {"ms": 0, "touches": [{"id": 0, "x": 0.5, "y": 0.45}]}, {"ms": 60, "touches": []},
      {"ms": 260, "touches": [{"id": 0, "x": 0.5, "y": 0.45}]}, {"ms": 320, "touches": []}]}
  ]
}
```

Coordinates are normalised `0...1`, origin top left, the space of both Manzanero's commands and the probe's `nx`/`ny`. Each `kind` maps to one Manzanero command; `gesture` takes the same frames as `manzanero gesture <json> --device <UDID>`. `id` is 1...64 ASCII letters, digits, `-`, `_` or `.`, unique in the plan. `settleSeconds` (0...5) and the tolerances are optional. Tolerances only flag a result; they never change whether an action counts as delivered.

The **built-in plan** has 14 actions, about 5 seconds of scheduled contact time: three taps, a 0.8-second long press, a swipe, a drag, two-contact multi-tap and pinch, three-contact multi-tap and multi-drag, four- and five-contact multi-taps, a one-finger double tap as a gesture sequence, and a two-contact sequence with staggered arrival and lift. Every point stays within x 0.25...0.75 and y 0.3...0.65, away from the edges where system gestures start and from the reset box. No action is a three-finger double tap, the iOS Zoom shortcut. `probe-touch plan` prints it.

## Expected effect of each action

The comparison expects what Manzanero schedules, from its sources: a tap or multi-tap holds 80 ms; a long press holds its seconds; generated movement (swipe, drag, multi-drag, pinch) releases 1 ms after the requested duration; a gesture sequence releases a contact at the first frame that omits it, and an id that reappears is a new contact. A gesture, as in the probe, runs from a first contact down until none remain down, so a sequence with an empty frame in the middle expects two gestures.

## Matching rules

Host and device clocks are never compared. Device timestamps are uptime; only their differences are used (hold durations).

1. **Windows.** Each readback gives the summary's `session` and `events` (the last `seq`). The events of an action are those with `before.events < seq <= after.events` in that session. An action without its own readback shares the window that the next readback closes.
2. **Session change.** If the session differs across a window, its actions are `session-changed`, and the new session's events in it are unattributed.
3. **Evidence, best first.**
   1. *Log* (`log`): the pulled log holds the window's session without gaps through the window's end.
   2. *Recent gestures* (`recent-gestures`): otherwise, the closing readback's `probe.touch.recent-gestures` readout, when it provably lists every gesture of the window. All of these must hold, or it is not used: the readout's session is the window's session (no session change); its `gestures` equals the closing summary's `gestures` (both read in the same snapshot); its entries are numbered `dropped + 1 … gestures` without gaps and `dropped + count == gestures`; no contact was down at either readback, so no gesture straddles a window edge; `dropped` is at most the opening summary's `gestures`, so none of the window's gestures was dropped; and the entries numbered above the opening summary's `gestures` account exactly for the window's counter differences (gestures, `began` = contacts, `ended`, `cancelled`, `moved` = sum of `moves`). The entries then stand in for the log's gestures, with positions, hold durations and `maxActive` per gesture but no per-event detail. When a present readout fails a condition, every action of the window gets a note saying which one.
   3. *Last gesture* (`readout`): otherwise, a single action that expects one gesture, where exactly one new gesture completed and the readback's `probe.touch.last-gesture` is that gesture.
   4. *Summary* (`summary`): otherwise, the differences of the summary's phase counters for a single action (counts only, no positions or timing).

   The log is replaced by any reset or relaunch and stops at its truncation limit, so the per-action readbacks are what keep earlier windows measurable. A readback without the recent-gestures element (an older probe build) simply skips step 2.
4. **Shared windows.** When several actions share a window, log or recent-gestures gestures are assigned to them in order only if the number received equals the number expected (anomaly `assigned-by-order`); otherwise all of them are `inseparable`. Without either, a shared window is always `inseparable`. With `--readback end` and no log, the built-in plan's 15 gestures fit in the readout's 32 entries; `--repeat 3` (45 gestures) does not, and the shared window is `inseparable`.
5. **Contacts.** Within an action, expected and received gestures are paired in order when their counts agree; otherwise all contacts are pooled and the action is flagged `gesture-count-mismatch`. Contacts are paired greedily by smallest distance between the expected start and the received `began` position.
6. **Late delivery.** If an action received nothing and the next action, in the adjacent window of the same session, received more gestures than it expects, both are flagged `late-delivery-suspected`. Events are never moved between windows: the pattern also fits a lost touch followed by a stray one. A longer `--settle` separates the two explanations.
7. **Errors.** Start error is received `began` minus expected start; end error is received `ended`/`cancelled` minus expected end; both as `dx`, `dy` and distance, normalised. Hold error is received minus expected hold, from device timestamps. Received `maxActive` is the probe's highest `active` during the action's gestures.

### Status

| Status | Meaning |
| --- | --- |
| `delivered` | Every expected contact began and ended (none cancelled), no extra contacts, the expected number of contacts were down at once, and the gesture count matched |
| `partial` | Something arrived, but not all of the above |
| `missing` | Nothing arrived in the window |
| `inseparable` | Events shared with other actions cannot be split |
| `session-changed` | The probe was reset or relaunched inside the window |
| `no-data` | No readback closed the window and the log cannot stand in |
| `not-sent` | The runner stopped before the action |

Rates use the *measured* actions (`delivered`, `partial`, `missing`) as denominator. A sent action that is `inseparable`, `session-changed` or `no-data` is reported but not measured.

### Anomalies

`dispatch-failed`, `received-despite-dispatch-failure`, `missing-contacts`, `extra-contacts`, `cancelled-contacts`, `unfinished-contacts` (no end in the window), `contact-without-began`, `max-active-short`, `gesture-count-mismatch`, `no-movement` (a moving path produced no `moved` event), `position-out-of-tolerance`, `duration-out-of-tolerance`, `unmatched-callbacks` (the summary's `unmatched` grew), `contacts-still-down`, `session-changed`, `inseparable`, `assigned-by-order`, `log-unusable` (a log was pulled but does not cover the window), `open-window` (closed by the end of the log, not a readback) and `late-delivery-suspected`.

## Output

Each live run writes a new directory, by default `tmp/probe-touch/<yyyyMMdd-HHmmss>` (UTC):

| File | Contents |
| --- | --- |
| `plan.json` | The plan as run |
| `run.json` | Options, preflight and baseline readbacks, every attempt with its dispatch outcome and readback, every command with exit status and host elapsed time, stop reason, pull result and the device state left. Rewritten after each step |
| `raw/NNN-<label>.stdout`, `.stderr` | Raw output of each Manzanero invocation |
| `touch-log.jsonl` | The pulled probe log |
| `report.json` | The comparison |
| `summary.txt` | The human-readable summary, also printed on stdout |

`report.json` (format `v: 1`) has:

- `summary`: actions planned, sent and measured; `statusCounts`; `deliveryRate`; `contactsExpected`, `contactsDelivered`, `contactDeliveryRate`; distributions (`count`, `min`, `median`, `mean`, `max`) of `startError`, signed `startDx` and `startDy`, `endError`, signed `holdError` and `holdErrorAbsolute`; `byKind`; `contactCounts` (for each scheduled number of simultaneous contacts, how many actions with log, recent-gestures or last-gesture evidence reached it and the received `maxActive` distribution); `anomalyCounts` (actions showing each anomaly); `sourceCounts` (measured actions per evidence source: `log`, `recent-gestures`, `readout`, `summary`).
- `actions`: per action, its arguments, status, evidence source (`log`, `recent-gestures`, `readout`, `summary` or `none`), dispatch outcome, window, expected and received gesture and contact counts, `receivedMaxActive`, `contactsDelivered`, per-contact results (expected contact, received contact, start and end error, hold error), extra contacts, anomalies, notes, and `identity` (`matched`, `not-checked` or `mismatched`) of the readback taken after the action, omitted when the action has no readback of its own.
- `log`: whether a log was available, its sessions (reason, events, contiguous `seq` range, truncation), malformed lines, an incomplete final line and sequence breaks.
- `unattributed`: log events before the run, after the run, after a session change, and in sessions the readbacks never saw.
- `identity`: `expectedBundleID` and, over the baseline and per-action readbacks, `readbacks`, `matched`, `notChecked` and `mismatched`. `mismatched` is 0 in a run the runner made, because such a readback stops it and is not kept; it can be non-zero only in an edited `run.json`. A note says how many readbacks were not checked.
- `sessions` seen by the readbacks, `tolerances` and `notes`.

`run.json` keeps each readback's `recentGestures` readout and observed `bundleID` (both omitted when absent). `summary.txt` adds an `Evidence:` line with the source counts and a `Foreground identity` line.

## What has and has not been verified

Verified on 2026-11-15 on macOS 27.2.1 with Xcode 27.2 (27B52) and Swift 6.4.2, without any device or simulator:

- `mise run probe-app:test` passes all 66 tests with zero warnings: the 22 original recorder tests, 2 decoding tests, and 42 measurement tests covering plan parsing and validation, command arguments, expected schedules, log parsing (malformed and cut-off lines, truncation, sequence gaps, several sessions), gesture reconstruction, the comparison (perfect delivery of every kind, coordinate and hold error, missing movement, dropped, serialised and cancelled contacts, missing actions, stray and late events, session change, truncated log, shared and open windows, dispatch failures, stuck contacts) and the runner end to end against a fake device (preflight refusal, unobserved reset, stuck contact, failed readback, relaunch mid-run, end-readback mode, timeouts, failed and directory pulls, dry run, argument parsing).
- `mise run test:probe-touch <UDID> --dry-run` printed the full plan, and `manzanero --dry-run` accepted all 17 distinct commands of the built-in plan.
- The `Process` invoker ran against `/usr/bin/false` in place of Manzanero: the preflight failed, the run stopped with exit 3 before any input, and `run.json` and the raw outputs were written.

The recent-gestures evidence and the identity check were added afterwards and checked the same way, without any device: `mise run probe-app:test` passed 93 tests with zero warnings. The 19 new measurement tests cover the log staying first, a two-gesture action and errors and shortfalls measured from the recent readout, a window whose gestures were partly dropped, gestures dropped before the window, inconsistent numbering, a readout that disagrees with the summary's gesture count or phase counters or session, a contact down at the window's end, an absent readout, a shared window split by order, the built-in plan's readout size, per-readback identity in the report, tree parsing of the attribute and the readout, and the runner end to end with the identity present and equal, absent, and different at preflight, at the baseline and after an action, plus `--readback end` without a log for one and three rounds. `mise run test:probe-touch <UDID> --dry-run` again exited 0 with 17/17 commands accepted.

At that point nothing had run on hardware. The phone runs that followed are under [phone runs](#phone-runs) below. Not verified then: that `tree` returns the probe's readouts on a phone (including an 8 KB recent-gestures value), that `nativeAttributes["3003"]` carries the probe's bundle identifier, that `press-id probe.touch.reset` resets it, that the settle time is long enough for UIKit to deliver the last events, the file layout `devicectl device copy from` produces at the destination (the runner accepts a file or a directory holding `touch-log.jsonl`), and every delivery figure.

### Simulator runs

On 2026-11-15 the runner ran with `--platform simulator` against the probe on one iPhone 17e simulator (iOS 27.2, 24B8117; Xcode 27.2; macOS 27.2.1), headless, through the in-process [simulator route](simulator-input.md). `mise run probe-app:test` passed 94 tests (one new for the platform option), and the physical dry run printed the same bytes as before the change.

- **Built-in plan, once:** the three taps, the long press, the swipe and the drag were `delivered` (start error median 0.0001, max 0.0002; hold error median +0.8 ms, max +0.9 ms). Two-contact multi-tap, pinch and three-contact multi-tap were refused by Manzanero and measured `missing` with `dispatch-failed`; the run then stopped after three consecutive dispatch failures, leaving five actions `not-sent`. Exit 3. This is the expected negative control.
- **Single-contact plan (three taps, 0.8 s and 2 s long presses, a 0.5 s and a 0.1 s swipe, a 0.8 s drag), five rounds:** 40 of 40 actions and 40 of 40 contacts `delivered`, all through the recent-gestures readout. Start error median 0.0001, max 0.0005 (normalised); hold error median +0.6 ms, max +5.4 ms; `maxActive` 1 every time. The foreground identity matched on all 41 readbacks. One more round after a second boot gave 8 of 8 (max start error 0.0005, max hold error +4.6 ms).

On 2026-11-16, after simulator multi-contact input was added (same simulator and versions, no runner change), the plan ran again:

- **Two-contact plan** (spread and inward pinch, two parallel and two diverging paths), five rounds: 20 of 20 actions and 40 of 40 contacts `delivered`, `maxActive` 2 every time.
- **Built-in plan, five rounds:** 70 of 70 actions and 145 of 145 contacts `delivered`, all through the recent-gestures readout; identity matched on all 71 readbacks. Per scheduled contact count:

| Contacts | Actions delivered | Contacts delivered | Start error median / max | Hold error (absolute) median / max |
| --- | --- | --- | --- | --- |
| 1 | 35/35 | 40/40 | 0.0002 / 0.0002 | 1.1 / 20.5 ms |
| 2 | 15/15 | 30/30 | 0.0004 / 0.0005 | 3.0 / 19.3 ms |
| 3 | 10/10 | 30/30 | 0.0001 / 0.0002 | 0.7 / 4.0 ms |
| 4 | 5/5 | 20/20 | 0.0001 / 0.0001 | 1.0 / 4.1 ms |
| 5 | 5/5 | 25/25 | 0.0004 / 0.0004 | 2.1 / 4.8 ms |

- **Landscape and iPad** (after rotation support, `--any-orientation`): the built-in plan, five rounds each, delivered 70 of 70 actions and 145 of 145 contacts on the iPhone 17e in landscape left and right, and on an iPad mini (A17 Pro) in portrait and landscape left; per-contact-count figures are in [verification](verification.md#rotation-and-ipad-on-the-simulator).
- **iPhone Duo, inner display** (2026-11-17, unfolded, `--any-orientation`): the built-in plan once delivered 14 of 14 actions and 29 of 29 contacts through the display's own Universal HID touchscreen ([verification](verification.md#the-duos-inner-display)).

Not shown by these runs: anything about a phone, and anything the probe log would add (per-event order), since there is no simulator pull.

### Phone runs

On 2026-11-15/16 the runner ran against the probe on the iPhone 13 mini (iOS 27.2.1, wired). `tree` returned the three readouts, `nativeAttributes["3003"]` carried the probe's bundle identifier, `press --id probe.touch.reset` reset it without recording a touch, and the log pull wrote a single file. The built-in plan delivered 14 of 14 actions in one round, but 66 of 70 over five rounds, and a tap-versus-hold plan showed short gestures lost whole. That led to the input drain after the completion barrier; with it the tap-versus-hold plan delivered 80 of 80 and the built-in plan 70 of 70 actions and 145 of 145 contacts. After the move to the operation-first grammar, two rounds delivered 28 of 28 actions and 58 of 58 contacts. Details and timing figures: [verification](verification.md#touch-delivery-measured-with-the-probe-app). A recent-gestures value near its 8 KB bound has not been read on a phone.

## Known limits

- Only taps, long presses, swipes, drags, multi-taps, multi-drags, pinches and gesture sequences are planned. Buttons, keys, typing and accessibility presses are out of scope.
- The tree readback is a separate CLI process per action, each with its own tunnel and AX session. That costs seconds per action, so per-action windows suit delivery and geometry but not rapid back-to-back timing. `--readback end` removes the gaps but relies on gesture order and has no foreground check between actions.
- The tree identifies the probe by its accessibility identifiers. The bundle identifier check uses `nativeAttributes["3003"]`, whose meaning rests on one observation of Settings on one phone; where the attribute is absent the identity is not checked.
- The recent-gestures readout lists at most 32 gestures and about 8 KB. A window with more gestures than it still lists (for example `--readback end` with `--repeat 3`) falls back to the last-gesture readout or counts when there is no usable log. It carries no per-event detail, so the order of events across contacts within a gesture is known only from the log.
- The probe sees only what reaches its UIKit view. A missing touch cannot be attributed to Manzanero, the transport or iOS.
