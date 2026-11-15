# Next live check plan

This page lists what still has to be run on a physical iPhone. It is a plan, not a record: results go in [verification](verification.md), and steps are removed from here once they are recorded there.

The first session (2026-11-15) covered the guarded wake, the command service queue, the device lease across two processes, interruption, the accessibility wait and the trimmed bridge. See [the record](verification.md#first-live-run-of-the-queue-lease-wait-and-trimmed-bridge). Two things stopped it: native recording produced no packets, and the probe app could not be signed.

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices physical`. If the display is off, `mise run cli physical <UDID> wake` turns it on. Inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

## Blocked on a person

- **Firewall rule.** Allow incoming connections for the executable path that `mise run cli doctor` prints in its `Firewall` entry, then run step 4. See [recording](recording.md#the-macos-firewall-can-drop-the-video).
- **Xcode account.** `build-run` failed with "No Accounts" and a profile that does not include the phone. Sign in under Xcode > Settings > Accounts for the team in `.env.local`, then run step 1.

## Still unverified

| Change | Risk if wrong |
| --- | --- |
| `build-run` provisioning flags and install | Probe app cannot be installed on the phone |
| Probe app on hardware | Readback through `tree`, reset through `press-id`, log `pull` |
| Touch measurement runner | Wrong matching against a real log |
| Native recording | Receives no packets. The macOS firewall has no rule for the `manzanero` executable; not yet re-run with one |

## Order

1. **Install the probe app.** See [probe app signing](probe-app.md#signing-for-a-physical-device).
   ```sh
   mise run probe-app:generate
   mise run cli physical <UDID> build-run tmp/probe-app/generated/ProbeApp.xcworkspace ProbeApp --allow-provisioning-updates --allow-device-registration
   ```
   Drop `--allow-device-registration` if the phone is already registered with the team. If the build fails, keep the raw log path it prints.
2. **Probe readback by hand**, before trusting the runner.
   ```sh
   mise run cli physical <UDID> tree                               # expect probe.touch.summary with a JSON value
   mise run cli physical <UDID> tap 0.5 0.45
   mise run cli physical <UDID> tree                               # began 1, ended 1, position near 0.5, 0.45
   mise run cli physical <UDID> press-id probe.touch.reset
   mise run cli physical <UDID> tree                               # new session; did the reset arrive as a touch?
   mise run cli physical <UDID> pull <bundle-id> Documents/touch-log.jsonl tmp/live/touch-log.jsonl
   ```
3. **Measurement run.** See [the runner](probe-touch-runner.md).
   ```sh
   mise run test:probe-touch <UDID> --dry-run
   mise run test:probe-touch <UDID>
   ```
   Read `tmp/probe-touch/<timestamp>/summary.txt`. Repeat with `--repeat 5` only after one clean run.
4. **Native recording**, once the firewall rule exists.
   ```sh
   mise run cli doctor                                             # Firewall entry should read allowed
   mise run cli --recording-backend coredevice physical <UDID> record tmp/live/check.mp4 3 hevc
   ```
   If packets still do not arrive with the rule in place, the firewall was not the whole cause: compare the opt-in `test:media-packets` diagnostic, which received packets on 2026-11-15.

## Questions still open

- Do the earlier unexplained tap misses reproduce against the probe, and if so are the touches absent from the log or delivered at another position?
- Does `press-id` activate the reset element through accessibility, or does iOS synthesize a tap that the probe records?
- Does `pull` read `Documents/` for a development-signed app, and does it write a file or a directory?
- Do three, four and five injected contacts arrive as that many simultaneous touches, and is any cancelled by system gestures?
- How close are received hold durations to the requested ones, and is a 0.5 s settle enough before readback?
- Does native recording work again once the firewall allows the executable, and was the same thing behind the earlier intermittent startup failures?
- Why did one wait report its subscription stop as unconfirmed?

## Stop conditions

Stop and record the state if a system prompt appears, an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else.
