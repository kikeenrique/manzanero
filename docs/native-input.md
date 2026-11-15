# Physical input

Physical buttons, keyboard, touch and gestures use Apple interfaces in the `manzanero` process. No helper build is needed. Start with a paired, prepared, awake and unlocked device; use [readiness](readiness.md) for preparation observations.

## Basic commands

```sh
manzanero physical <UDID> button home
manzanero physical <UDID> tap 0.5 0.5
manzanero physical <UDID> swipe 0.5 0.8 0.5 0.2 0.6
manzanero physical <UDID> long-press 0.5 0.5 0.8
manzanero physical <UDID> key backspace
```

`drag` and `swipe` use the same point-to-point movement. Coordinates are normalized `0...1` in the current interface, origin at the top left. Movement duration is `0.03...10` seconds; a stationary long press accepts `0.1...10` seconds.

The direct backend is the only physical backend and the default. `--physical-backend coredevice` selects it explicitly and is kept for existing scripts; any other value fails as an unsupported physical backend. Pairing files are not accepted. A failed action is not replayed through another backend.

## Direct buttons

Buttons are `home`, `lock`, `volume-up` and `volume-down`. The bridge sends one down/up pair with readiness and completion barriers. `lock` uses a 0.4-second hold; the others use 80 ms.

A barrier acknowledges transport progress, not a UI effect. Home has scoped visual verification on iPhone 13 mini. One side-button check saw display power change from off to active, but the next media probe found it off again. `button lock` is a toggle, not an idempotent wake command; do not replay it as an automatic wake strategy. Wake duration and unlock remain unverified.

## Waking a dark display

```sh
manzanero physical <UDID> wake [--no-dismiss]
```

`wake` is for a prepared test device (no passcode, Auto-Lock set to Never) whose display was turned off. Because the side button toggles, it presses only when a press can only help:

1. Read Apple's display and passcode state. If the display is on, report `already-awake` and send nothing. If the state is not `on` or `off`, report `unknown-display-state` and send nothing.
2. Read it a second time. Only if both readings say off, press the side button once.
3. Read the state again. If the display is not on, report `not-awake`; the button is never pressed a second time.
4. If no passcode is required, press Home once to leave the lock screen (skipped with `--no-dismiss`), and read the state a last time. If a passcode is required or its state is unknown, report `awake-locked` and leave the lock screen alone. No passcode is ever entered.

The result is JSON with `status`, `displayPowerBefore`, `displayPower`, `sideButtonPressed` and `homePressed`. `already-awake` and `awake` exit 0; the other statuses exit 1 with an `action` explaining what a person should do. Over MCP the tool is `wake_device`, and those statuses are answers rather than errors. `wake` takes the device lease like any other input.

An `awake` status means Apple reported the backlight on. It does not prove the UI is unlocked or which screen is showing, so inspect before acting. Local tests cover every branch. On hardware it has been observed once, on an iPhone 13 mini without a passcode: a dark display was woken to the Home screen and stayed on, and a second call on the lit display sent nothing. See [verification](verification.md#guarded-wake).

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

Supported names are `return`, `escape`, `backspace`, `tab`, `space`, `up`, `down`, `left` and `right`. Keys act at the current focus and do not change the clipboard. Backspace has visual evidence in Settings search; broader key/layout/field coverage remains unverified.

For a string, use [US-layout ASCII typing](physical-typing.md). Unicode entry uses the separate clipboard operation below.

## Direct Unicode paste

```sh
manzanero physical <UDID> paste 'mañana 🚀 中'
```

Paste accepts `1...65536` UTF-8 bytes without NUL. It uses Apple's `devicectl device pasteboard copy`, then sends one native Command+V sequence at the current caret/selection.

**Paste replaces the phone clipboard and does not restore it.** It does not focus a field, select all, submit, approve a paste prompt or verify the inserted value. The text reaches the Apple subprocess through private file-backed stdin under `tmp/`, not shell interpolation.

An unconfirmed clipboard copy sends no paste keys and reports uncertain clipboard state. Failure or cancellation after a confirmed copy can leave the clipboard replaced and insertion unknown. An iOS Allow Paste prompt can remain after dispatch completes. Inspect the screen rather than repeating insertion automatically.

Accented text, emoji and CJK text were visually verified in Settings search after explicit approval of the visible paste prompt. Other apps and permission states need their own checks.

## Receipts and partial effects

Direct input returns JSON identifying the operation/backend with `verified: false` and `releaseVerified: false`. Paste and typing also report insertion as unverified. A successful receipt is a dispatch result; verify behavior with a fresh screenshot/tree or an application assertion.

Failure after a down event can leave a partial effect. The tool cannot roll back typed text, clipboard changes, scroll position or an application action.

## Task cancellation and release attempts

Schedulers check cancellation before each event and during waits using sleep chunks of at most 10 ms. That bounds the requested sleep chunk, not end-to-end latency.

Cancellation or observed transport failure stops future events and attempts release at the last attempted positions or of the attempted key set. Ordinary keys release before modifiers. A pre-cancelled action sends no down; balanced completion adds no duplicate release. Cancellation propagates after the release/barrier path returns.

Socket setup can wait up to 15 seconds, discovery/readiness barriers up to three seconds each, and the completion barrier up to three seconds. Blocking Apple calls can delay cooperative cancellation.

## Ownership across processes

Physical input, accessibility press/scroll and native recording take a per-device lease before dispatch. A second `manzanero` process that tries to send input to, or natively record, the same device is refused immediately with `Device is controlled by another manzanero process`, naming the holder's process ID and operation; it never waits or queues. Observations (`tree`, `screen`, `screenshot`, `readiness`, app and file commands) take no lease. The `devicectl` recording backend takes none either.

Within one process the lease is shared, so an MCP server can record and send input at the same time. The lease is an advisory lock on a file under `~/Library/Application Support/manzanero/leases/`, keyed by the resolved CoreDevice identifier so every alias of a device maps to one lease. The kernel releases it when the owning process exits for any reason, including a crash or SIGKILL.

[Simulator input](simulator-input.md) and simulator press/scroll take the same lease, keyed by the simulator UUID; on one simulator a second process's tap during a long press was refused this way.

The lease establishes host-side exclusivity only. It does not show that an earlier owner released its contacts, keys or stream on the device, and it does not restrain Xcode or other tools. Local tests cover refusal, sharing and release; no live two-process check has been run.

## CLI signals

During direct physical HID commands, SIGINT/SIGTERM cancel owned work, attempt cleanup and exit 130/143 without a success receipt. A second signal or the 30-second grace deadline forces exit. Force exit, SIGKILL, crashes and disconnects cannot guarantee device-side release.

MCP also cancels/drains owned operations on EOF and signals; see [MCP shutdown](mcp.md#shutdown-and-operation-ownership).

## Verification and remaining limits

Scoped iPhone 13 mini checks cover Home, Settings tap/drag, long press, two-contact Maps zoom, selected timed gestures, ASCII typing, Unicode paste and Backspace. Delivery has since been measured with the [probe app](probe-app.md): after one fix, 150 of 150 actions over fifteen rounds arrived, from single taps to five simultaneous contacts, with start positions within 0.0005 of the screen and holds within 12 ms.

The fix explains the earlier taps and Home presses that had no visible effect. The connection used to be cancelled as soon as the completion barrier was acknowledged, and a gesture shorter than about 0.2 s could be discarded whole by the device while its receipt still said `dispatched`. The connection now stays open for 400 ms after the barrier, so every input call takes at least that long. A receipt is still not an effect: inspect after every action.

Local tests cover encoding, scheduling, rotation, invalid input and attempted cleanup. They do not prove hardware delivery, exact timing or release after failure. Other Apple families, rotations, quarantine after an uncertain release and reliable unattended recovery remain incomplete. [Verification](verification.md) records positive and negative results.

## Historical helper implementation (removed)

Earlier implementations invoked ipb or a Rust idevice bridge. Their routes, sources and patches have been removed (git history keeps them), and runtime policy would refuse those executables. Earlier helper receipts and cleanup behavior must not be treated as direct-backend evidence. See [dependencies and provenance](dependencies.md#retired-helpers).
