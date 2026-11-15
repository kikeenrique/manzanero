# Next live check plan

Several changes have landed with local tests only. This page orders the checks for the next session with a physical iPhone, so each step rests on the one before it and a failure points at one change. It is a plan, not a record: results go in [verification](verification.md), and this page is rewritten or removed once they are in.

Run from the repository root with the device paired, awake and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices physical`. Inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

## What is unverified

| Change | Risk if wrong |
| --- | --- |
| Command service on its own queue | Every operation; cancellation through SIGINT |
| Per-device lease before input and native recording | Every input refused, or a second process not refused |
| `doctor` private-interface report | Wrong availability report (reads only) |
| Native media guard for five negotiator methods | Native recording refused on a host where it worked |
| Bounded accessibility wait (`wait-id`, `wait-label`) | Wrong result, exhausted session budget, or cleanup not acknowledged |
| `build-run` hardware-UDID destination and provisioning flags | Probe app cannot be built or installed on the phone |
| Probe app on hardware | Readback through `tree`, reset through `press-id`, log `pull` |
| Touch measurement runner | Wrong matching against a real log |

## Order

1. **Host only.** `mise run build`, then `mise run cli doctor`. Every `private-interface` entry used by commands should report `available`. No device is contacted.
2. **Read-only device checks.** These exercise the queue change without sending input.
   ```sh
   mise run cli physical <UDID> readiness
   mise run cli physical <UDID> tree
   mise run cli physical <UDID> screenshot tmp/live/before.png
   ```
3. **One input, on a harmless screen** (Settings root). This is the first use of the lease on hardware.
   ```sh
   mise run cli --dry-run physical <UDID> button home
   mise run cli physical <UDID> button home
   mise run cli physical <UDID> tap 0.5 0.5
   ```
   Then confirm no stale lock remains: `ls ~/Library/Application\ Support/manzanero/leases/` should show a zero-length file for the device.
4. **Lease across two processes.** In one terminal start a long hold; in another, send a tap during it.
   ```sh
   mise run cli physical <UDID> long-press 0.5 0.5 8
   mise run cli physical <UDID> tap 0.5 0.5        # second terminal, within 8 s
   mise run cli physical <UDID> tree               # second terminal: reads are not refused
   ```
   Expected: the tap fails at once with `Device is controlled by another manzanero process` and names the first process; the tree read succeeds; after the hold ends, a tap is accepted again.
5. **Interrupt.** Start the same long press and press Ctrl-C after two seconds. Expected: exit 130, no success receipt, and the next input is accepted (the lease was released).
6. **Native recording.** One short capture, to confirm the added media guard does not refuse a working host.
   ```sh
   mise run cli --recording-backend coredevice physical <UDID> record tmp/live/check.mp4 3 hevc
   ```
7. **Accessibility wait**, with Settings in front. See [the wait](direct-accessibility.md).
   ```sh
   mise run cli physical <UDID> wait-label 'General' --timeout 5                                 # exit 0 on the first poll
   mise run cli physical <UDID> wait-label 'Does Not Exist' --timeout 3; echo $?                 # exit 124, status timed-out
   mise run cli physical <UDID> press-label 'General'
   mise run cli physical <UDID> wait-label 'General' --until gone --timeout 5                    # met after navigation
   ```
   Note how long one poll takes, and whether cleanup is acknowledged after the timeout. Use the device's own language for the labels.
8. **Install the probe app.** Needs `DEVELOPMENT_TEAM` in `.env.local` and Xcode signed in to that team. See [probe app signing](probe-app.md#signing-for-a-physical-device).
   ```sh
   mise run probe-app:generate
   mise run cli --dry-run physical <UDID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --allow-provisioning-updates --allow-device-registration
   mise run cli physical <UDID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --allow-provisioning-updates --allow-device-registration
   ```
   Drop `--allow-device-registration` if the phone is already registered with the team. If the build fails, keep the raw log path it prints.
9. **Probe readback by hand**, before trusting the runner.
   ```sh
   mise run cli physical <UDID> tree                               # expect probe.touch.summary with a JSON value
   mise run cli physical <UDID> tap 0.5 0.45
   mise run cli physical <UDID> tree                               # began 1, ended 1, position near 0.5, 0.45
   mise run cli physical <UDID> press-id probe.touch.reset
   mise run cli physical <UDID> tree                               # new session; did the reset arrive as a touch?
   mise run cli physical <UDID> pull <bundle-id> Documents/touch-log.jsonl tmp/live/touch-log.jsonl
   ```
10. **Measurement run.** See [the runner](probe-touch-runner.md).
   ```sh
   mise run test:probe-touch <UDID> --dry-run
   mise run test:probe-touch <UDID>
   ```
   Read `tmp/probe-touch/<timestamp>/summary.txt`. Repeat with `--repeat 5` only after one clean run.

## Questions the session should answer

- Do the earlier unexplained tap misses reproduce against the probe, and if so are the touches absent from the log or delivered at another position?
- Does `press-id` activate the reset element through accessibility, or does iOS synthesize a tap that the probe records?
- Does `pull` read `Documents/` for a development-signed app, and does it write a file or a directory?
- Do three, four and five injected contacts arrive as that many simultaneous touches, and is any cancelled by system gestures?
- How close are received hold durations to the requested ones, and is a 0.5 s settle enough before readback?
- Does `xcodebuild` accept the destination built from the hardware UDID, and is the 60 s install timeout enough?

## Stop conditions

Stop and record the state if the display turns off, a system prompt appears, an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else.
