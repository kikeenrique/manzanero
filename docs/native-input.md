# Physical input

Physical buttons, keyboard, touch and gestures use Apple interfaces in the `manzanero` process. No helper build is needed. Start with a paired, prepared, awake and unlocked device; use [readiness](readiness.md) for preparation observations.

## Basic commands

```sh
manzanero button home --device <UDID>
manzanero tap 0.5 0.5 --device <UDID>
manzanero swipe 0.5 0.8 0.5 0.2 0.6 --device <UDID>
manzanero long-press 0.5 0.5 0.8 --device <UDID>
manzanero key backspace --device <UDID>
```

`drag` and `swipe` use the same point-to-point movement. Coordinates are normalized `0...1` in the current interface, origin at the top left. Movement duration is `0.03...10` seconds; a stationary long press accepts `0.1...10` seconds. Put `--` before operands that begin with `-` (`tap --device <UDID> -- -0.1 0.5` reaches the coordinate check instead of being read as an option).

The direct backend is the only physical backend; there is no backend option. Pairing files are not accepted. A failed action is not replayed through another backend.

## Direct buttons

Buttons are `home`, `lock`, `volume-up` and `volume-down`, and on an Apple Watch since 2026-11-25 `side` and `action` ([watch buttons](other-families.md#digital-crown-and-side-button-apple-watch); another device is refused before input). The bridge sends one down/up pair with readiness and completion barriers. `lock` uses a 0.4-second hold; the others use 80 ms.

A barrier acknowledges transport progress, not a UI effect. Home has scoped visual verification on iPhone 13 mini. One side-button check saw display power change from off to active, but the next media probe found it off again. `button lock` is a toggle, not an idempotent wake command; do not replay it as an automatic wake strategy. Wake duration and unlock remain unverified.

## Waking a dark display

```sh
manzanero wake [--no-dismiss] --device <UDID>
```

`wake` is for a prepared test device (no passcode, Auto-Lock set to Never) whose display was turned off. Because the side button toggles, it presses only when a press can only help:

1. Read Apple's display and passcode state. If the display is on, report `already-awake` and send nothing. If the state is not `on` or `off`, report `unknown-display-state` and send nothing.
2. Read it a second time. Only if both readings say off, press the side button once.
3. Read the state again. If the display is not on, report `not-awake`; the button is never pressed a second time.
4. If no passcode is required, press Home once to leave the lock screen (skipped with `--no-dismiss`), and read the state a last time. If a passcode is required or its state is unknown, report `awake-locked` and leave the lock screen alone. No passcode is ever entered.

The result is JSON with `status`, `displayPowerBefore`, `displayPower`, `sideButtonPressed` and `homePressed`. `already-awake` and `awake` exit 0; the other statuses exit 1 with an `action` explaining what a person should do. On an Apple TV, which has no side button and whose television has no backlight state to read, `wake` does what [`remote wake`](other-families.md#sleep-and-wake) does since 2026-11-23, with `operation: wake` in the result: a screenshot tells whether it is asleep, and only then is Home pressed once; `--no-dismiss` changes nothing there. The `external-display` status is left for a device with an external display that does not say it is an Apple TV. Over MCP the tool is `wake_device`, and those statuses are answers rather than errors. `wake` takes the device lease like any other input.

An `awake` status means Apple reported the backlight on. It does not prove the UI is unlocked or which screen is showing, so inspect before acting. Local tests cover every branch. On hardware it has been observed on one iPhone 13 mini. Without a passcode: a dark display was woken to the Home screen and stayed on, and a second call on the lit display sent nothing ([verification](verification.md#guarded-wake)). With a passcode: the side button was pressed, Home was not, and the status was `awake-locked` with exit 1; a second call on the lit lock screen was `already-awake` ([verification](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen)). The lock screen sleeps again within about ten seconds. To have a person unlock it, follow with [`handoff --until unlocked`](handoff.md#watching-the-device---until).

## Touch preparation and dispatch

Before touch, the implementation:

1. Validates all coordinates and timing.
2. Resolves fresh CoreDevice identity and Developer Mode.
3. Requires one awake integrated primary display with bounded, typed geometry and known orientation.
4. Rechecks display metadata before dispatch and discovers the relevant native service/surface.
5. Sends one bounded schedule, then attempts release and a completion barrier.

An off display produces wake/unlock guidance; unknown power or invalid geometry is reported separately. These checks do not prove current UI unlock. Current-interface coordinates are rotated into portrait digitizer space. Nonzero native display orientation also requires agreeing device-orientation metadata. Rotation during an action is not monitored.

Single-contact touch and two-contact movement use Indigo digitizer events. Timed schedules, simultaneous multi-taps and three-to-five-path movement use Universal HID. See [multitouch](multitouch.md) and [complete-state schedules](gesture-sequences.md) for their contracts.

### Long-press

`long-press <x> <y> <seconds>` holds one point, then lifts. The application decides whether the hold opens a menu or has another effect. A 0.8-second Maps-icon hold opened its context menu in CLI and MCP checks on iPhone 13 mini; this does not establish a universal gesture threshold.

## Direct named keyboard keys

Supported names are `return`, `escape`, `backspace`, `tab`, `space`, `up`, `down`, `left` and `right`. Keys act at the current focus and do not change the clipboard. On the iPhone 13 mini, twelve separate `key backspace` calls removed twelve letters and two separate `key space` calls arrived; other keys and fields have scoped or no evidence.

For a string, use [typing in a named keyboard layout](physical-typing.md). For Unicode text, use `set-value`, which replaces a named element's value through accessibility ([physical typing](physical-typing.md)), or the clipboard operation below.

## Direct Unicode paste

```sh
manzanero paste 'mañana 🚀 中' --device <UDID>
```

Paste accepts `1...65536` UTF-8 bytes without NUL. It uses Apple's `devicectl device pasteboard copy`, then sends one native Command+V sequence at the current caret/selection.

**Paste replaces the phone clipboard and does not restore it.** It does not focus a field, select all, submit, approve a paste prompt or verify the inserted value. The text reaches the Apple subprocess through private file-backed stdin under `tmp/`, not shell interpolation.

An unconfirmed clipboard copy sends no paste keys and reports uncertain clipboard state. Failure or cancellation after a confirmed copy can leave the clipboard replaced and insertion unknown. An iOS Allow Paste prompt can remain after dispatch completes. Inspect the screen rather than repeating insertion automatically.

Accented text, emoji and CJK text were visually verified in Settings search after explicit approval of the visible paste prompt. Other apps and permission states need their own checks.

## Receipts and partial effects

Direct input returns JSON identifying the operation/backend with `verified: false` and `releaseVerified: false`. Paste and typing also report insertion as unverified. A successful receipt is a dispatch result; verify behavior with a fresh screenshot/tree or an application assertion.

Failure after a down event can leave a partial effect. The tool cannot roll back typed text, clipboard changes, scroll position or an application action.

**Locked devices.** Input is refused while the display is off (`display-off`), but not because a device is locked: an awake lock screen takes touches, keys and buttons, and sometimes that is what is wanted (its camera and torch buttons). So every physical input receipt, including `press`, `scroll` and `set-value`, carries `passcodeRequired`, read from Apple's lock state once after the input: `true`, `false`, or `null` when it could not be read. When it is `true` the receipt also has a `lockNote` saying the input may have gone to the lock screen. The read comes after the input so the input's timing is unchanged, and a failed read never makes a sent input fail. `wake` reports the same field itself; simulators have no such field. Checked on one iPhone 13 mini with a passcode ([verification](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen)).

## Task cancellation and release attempts

Schedulers check cancellation before each event and during waits using sleep chunks of at most 10 ms. That bounds the requested sleep chunk, not end-to-end latency.

Cancellation or observed transport failure stops future events and attempts release at the last attempted positions or of the attempted key set. Ordinary keys release before modifiers. A pre-cancelled action sends no down; balanced completion adds no duplicate release. Cancellation propagates after the release/barrier path returns.

Socket setup can wait up to 15 seconds, discovery/readiness barriers up to three seconds each, and the completion barrier up to three seconds. Blocking Apple calls can delay cooperative cancellation.

## Ownership across processes

Physical input (including `wake`), accessibility press/scroll, `set-value`, `detect-layout`, native recording and `frames` take a per-device lease before dispatch. A second `manzanero` process that tries to send input to, or natively record, the same device is refused immediately with `Device is controlled by another manzanero process`, naming the holder's process ID and operation; it never waits or queues. Observations (`tree`, `screen`, `screenshot`, `readiness`, app and file commands) take no lease. The `devicectl` recording backend takes none either.

Within one process the lease is shared, so an MCP server can record and send input at the same time. The lease is an advisory lock on a file under `~/Library/Application Support/manzanero/leases/`, keyed by the resolved CoreDevice identifier so every alias of a device maps to one lease. The kernel releases it when the owning process exits for any reason, including a crash or SIGKILL.

[Simulator input](simulator-input.md) and simulator press/scroll take the same lease, keyed by the simulator UUID; on one simulator a second process's tap during a long press was refused this way.

The lease establishes host-side exclusivity only. It does not show that an earlier owner released its contacts, keys or stream on the device ([quarantine](#quarantine-after-an-uncertain-release) covers the cases the Mac can know about), and it does not restrain Xcode or other tools. Local tests cover refusal, sharing and release. On the iPhone 13 mini, a second process's `tap` during an 8-second `long-press` was refused at once and a `tree` from it succeeded; after the hold a `tap` was accepted ([verification](verification.md#first-live-run-of-the-queue-lease-wait-and-trimmed-bridge)). That is one pair of processes and one timing.

## Quarantine after an uncertain release

A touch, button or key input can end without its release being known: the bridge reports `input-outcome-unknown` (input was attempted and the end of it was not confirmed), or the process sending it exits first (a crash, SIGKILL, the forced exit after a second signal or the grace deadline). A contact, key or button may then still be held on the device, and further input would be read against it: a tap as a second finger, a key as a chord.

Manzanero cannot see that on the device, so it records it on the Mac and stops sending input until someone has looked:

- **What marks a device.** An operation that presses something (`tap`, `long-press`, `swipe`, `drag`, `pinch`, `multi-tap`, `multi-drag`, `gesture`, `button`, `key`, `type`, `paste`, `wake`, `remote`, `crown`, `detect-layout`) failing with `input-outcome-unknown`; or a new owner, or `clear-quarantine`, finding the lease note of such an operation under a free lock, which only an owner that exited without releasing leaves behind. Accessibility actions (`press`, `scroll`, `set-value`) hold nothing and never mark; `fold`, `unfold` and `hinge` send one event with no release; an abandoned `record` or `frames` owner holds a stream, not a contact, and does not mark.
- **What it refuses.** Every operation that takes the lease to send input or an accessibility action, in every `manzanero` process on this Mac, with `code: device-quarantined`, `inputSent: none`, `retry: after-action`, `action: clear-quarantine`. The message gives the reason and when it began. `tree`, `wait`, `screen`, `screenshot`, `record`, `frames` and the app and file commands still run, so the device can be inspected.
- **How it ends.** `manzanero clear-quarantine (--device <UDID> | --simulator <UUID>)` (MCP `clear_quarantine`) removes the mark and prints `status: cleared` with the reason, or `not-quarantined`. It sends nothing to the device and releases nothing on it; it records that the caller inspected it. The mark is a `<device>.quarantine` file beside the lease, keyed like it, and survives restarts.
- **What does not mark.** SIGINT and SIGTERM: the release is sent before exit 130/143 and the lease note is cleared. A failure before any input (`transport-failed`, `inputSent: none`).

Nothing is sent to the device to release anything. On one simulator a long press killed with SIGKILL after 2 s was released by the simulator itself: the probe app recorded the contact ending, with none active ([verification](verification.md#quarantine-after-an-uncertain-release)). The iPhone 13 mini did the same on 2026-11-17, reporting the contact as ended at position `[0,0]` ([verification](verification.md#phone-session-of-2026-11-17)). A lost connection was observed on 2026-11-22: the human owner pulled the phone's cable 8 s into a 10-second `long-press` on the tool's own tunnel. The command failed at once with `input-outcome-unknown` (`inputSent: possible`, `retry: after-inspection`), the next `tap` was refused as `device-quarantined` with `since` at the moment of the failure, and the probe showed the contact ended by the phone after 6.66 s (`ended`, not `cancelled`, none active), again at position `[0,0]`; a normal tap afterwards ended where it began ([verification](verification.md#a-cable-pulled-during-a-long-press)). So a release the phone makes for itself may come at the screen's top-left corner, where another app could take it as a touch. A lost network path did the same the same night: a `gesture` sent over Wi‑Fi that switched the phone's Wi‑Fi off with one contact while another stayed held failed with `input-outcome-unknown` ("the Apple service barrier was not confirmed") and quarantined the device. A held key or button has not been observed on either, and cannot be produced on a phone from the CLI, so a release sequence for them would be untested input; they are in the [live check plan](live-check-plan.md).

## CLI signals

During direct physical HID commands, SIGINT/SIGTERM cancel owned work, attempt cleanup and exit 130/143 without a success receipt. A second signal or the 30-second grace deadline forces exit. Force exit, SIGKILL, crashes and disconnects cannot guarantee device-side release; the next input to that device is then refused until [`clear-quarantine`](#quarantine-after-an-uncertain-release).

MCP also cancels/drains owned operations on EOF and signals; see [MCP shutdown](mcp.md#shutdown-and-operation-ownership).

## Verification and remaining limits

Scoped iPhone 13 mini checks cover Home, Settings tap/drag, long press, two-contact Maps zoom, selected timed gestures, ASCII typing, Unicode paste and Backspace. Delivery has since been measured with the [probe app](probe-app.md): after one fix, 150 of 150 actions over fifteen rounds arrived, from single taps to five simultaneous contacts, with start positions within 0.0005 of the screen and holds within 12 ms.

The fix explains the earlier taps and Home presses that had no visible effect. The connection used to be cancelled as soon as the completion barrier was acknowledged, and a gesture shorter than about 0.2 s could be discarded whole by the device while its receipt still said `dispatched`. The connection now stays open for 200 ms after the barrier, so every input call takes at least that long. The value was measured on that phone: 50 ms lost about a third of short gestures, and 100, 200 and 400 ms lost none. A receipt is still not an effect: inspect after every action.

Local tests cover encoding, scheduling, rotation, invalid input and attempted cleanup. They do not prove hardware delivery, exact timing or release after failure. Other Apple families, rotations, device-side release after an uncertain one and reliable unattended recovery remain incomplete. [Verification](verification.md) records positive and negative results.

## Historical helper implementation (removed)

Earlier implementations invoked ipb or a Rust idevice bridge. Their routes, sources and patches have been removed (git history keeps them), and runtime policy would refuse those executables. Earlier helper receipts and cleanup behavior must not be treated as direct-backend evidence. See [dependencies and provenance](dependencies.md#retired-helpers).
