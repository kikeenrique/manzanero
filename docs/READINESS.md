# Physical-device readiness

```sh
appledevicescmd physical <device> readiness
```

This read-only check normalizes Xcode's device-details result into JSON: Developer Mode, developer disk image services, connection, pairing, issues, and preparation steps. It also returns a separate `ui` observation from Apple's display-power and passcode-state queries. It is available as MCP `device_readiness`.

| Status | Meaning |
| --- | --- |
| `blocked` | Developer Mode is explicitly disabled; enable it on the device before developer operations. |
| `needsPreparation` | Developer Mode, connection, and pairing are confirmed, but developer-image services are unavailable. |
| `unknown` | Required information is missing, unrecognized, or connection/pairing is not confirmed. |
| `prerequisitesPresent` | CoreDevice reports Developer Mode enabled, image services available, connected, and paired. This does not verify UI Automation or input/capture functionality. |

The command exits 0 only for `prerequisitesPresent`; other states still return full JSON with exit 1. MCP preserves that JSON under `structuredContent.result` and sets `isError: true` for non-ready reports. Unknown information is never interpreted as enabled/ready.

The top-level status and exit code retain their **CoreDevice prerequisite** meaning. Agents preparing UI work must inspect `ui` as well: a connected, prepared device can have `status: prerequisitesPresent` and `ui.status: needsUserAction` because its display is off.

## UI observations

Explicit CLI/MCP readiness resolves a fresh CoreDevice UUID, then queries `device info displays` and `device info lockState` with ten-second Apple-tool timeouts. The additional reads do not run during ordinary operation preflight. Dry runs perform no queries.

- `ui.displayPower`: `on`, `off` or `unknown`, based on exactly one primary display's recognized backlight state. Ambiguous, malformed, oversized or unsupported results remain unknown.
- `ui.passcodeRequired` and `ui.unlockedSinceBoot`: Apple's Boolean fields, omitted when unrecognized or unavailable. The lock-state result must match the resolved UUID. Display responses lacking an identity field remain bound to the explicit query target; all observations are sequential and non-atomic.
- `ui.status`: `needsUserAction` when wake/passcode preparation is reported, `unknown` when required observations are missing, otherwise `observed`. `observed` does not mean UI Automation or device control is ready.
- `ui.actions`, `ui.diagnostics`, `ui.limitations`: preparation steps and uncertainty. No raw Apple error payload is copied into these fields. Read failures preserve the CoreDevice report and leave unavailable UI fields unknown; cancellation propagates.

Apple's observed lock-state schema does not provide a verified current “UI unlocked” flag. `passcodeRequired: false` and `unlockedSinceBoot: true` must not be interpreted as proof that the current interface is unlocked. The CLI does not enter passcodes, attempt wake/unlock, or verify the Enable UI Automation switch.

`mise run test:mcp-readiness <hardware-UDID>` checks these observations through real MCP without input. Raw state and device identifiers remain in its private ignored test directory.

The decoder prefers the current `properties` dictionary, including enum-shaped Developer Mode values such as `{"disabled":{}}`. It falls back to deprecated fields only when the corresponding current field is absent. Developer-image availability currently requires a legacy-field fallback on the inspected Xcode version; if removed without a known replacement, it reports unknown.

## Preparing the phone

When Developer Mode is disabled, the report directs the user to **Settings → Privacy & Security → Developer Mode**, then to enable it, restart, unlock, and confirm **Turn On**. The CLI does not enable it, approve trust, or restart a phone. After enabling it, let the selected Xcode prepare developer support, then query readiness again. A device may be connected and paired while Developer Mode is disabled and no developer image is available.

## Automatic checks

Before physical Build & Run, recording, input, HID/accessibility, screenshots, process listing/launch/termination, or URL opening, the shared service queries readiness. A known disabled Developer Mode produces an actionable error before dispatching the operation. Dry runs do not query or alter a device.

Unknown Developer Mode or unavailable/unknown image services produce a diagnostic and allow the selected backend to enforce its own prerequisites. Some Xcode operations can prepare developer support automatically. If CoreDevice cannot query the device at all, the CLI reports that uncertainty and lets the backend proceed; an independently paired idevice connection must not be made dependent on Apple's separate pairing identity. Standalone `readiness` still reports query failures as errors.

App listing/install/uninstall, raw app-container operations, reports, and OS logs are not automatically blocked by this preflight; their individual services have different requirements. No readiness state proves their authorization. UI Automation, a verified current UI-unlocked state, usbmuxd reachability and actual UI effects are not checked. The explicit UI passcode/display observations above are separate from automatic CoreDevice preflight.

The user's selected physical test device is an iPhone 13 mini. Its observed disabled-mode/absent-image state and blocked recording check are recorded in [verification](VERIFICATION.md); private identifiers and raw device output remain under ignored `tmp/`.
