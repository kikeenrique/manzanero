# Physical-device readiness

```sh
appledevicescmd physical <device> readiness
```

This read-only check normalizes Xcode's device-details result into JSON: Developer Mode, developer disk image services, connection, pairing, issues, and preparation steps. It is also available as MCP `device_readiness`.

| Status | Meaning |
| --- | --- |
| `blocked` | Developer Mode is explicitly disabled; enable it on the device before developer operations. |
| `needsPreparation` | Developer Mode, connection, and pairing are confirmed, but developer-image services are unavailable. |
| `unknown` | Required information is missing, unrecognized, or connection/pairing is not confirmed. |
| `prerequisitesPresent` | CoreDevice reports Developer Mode enabled, image services available, connected, and paired. This does not verify UI Automation or input/capture functionality. |

The command exits 0 only for `prerequisitesPresent`; other states still return full JSON with exit 1. MCP preserves that JSON under `structuredContent.result` and sets `isError: true` for non-ready reports. Unknown information is never interpreted as enabled/ready.

The decoder prefers the current `properties` dictionary, including enum-shaped Developer Mode values such as `{"disabled":{}}`. It falls back to deprecated fields only when the corresponding current field is absent. Developer-image availability currently requires a legacy-field fallback on the inspected Xcode version; if removed without a known replacement, it reports unknown.

## Preparing the phone

When Developer Mode is disabled, the report directs the user to **Settings → Privacy & Security → Developer Mode**, then to enable it, restart, unlock, and confirm **Turn On**. The CLI does not enable it, approve trust, or restart a phone. After enabling it, let the selected Xcode prepare developer support, then query readiness again. A device may be connected and paired while Developer Mode is disabled and no developer image is available.

## Automatic checks

Before physical Build & Run, recording, input, HID/accessibility, screenshots, process listing/launch/termination, or URL opening, the shared service queries readiness. A known disabled Developer Mode produces an actionable error before dispatching the operation. Dry runs do not query or alter a device.

Unknown Developer Mode or unavailable/unknown image services produce a diagnostic and allow the selected backend to enforce its own prerequisites. Some Xcode operations can prepare developer support automatically. If CoreDevice cannot query the device at all, the CLI reports that uncertainty and lets the backend proceed; an independently paired idevice connection must not be made dependent on Apple's separate pairing identity. Standalone `readiness` still reports query failures as errors.

App listing/install/uninstall, raw app-container operations, reports, and OS logs are not automatically blocked by this preflight; their individual services have different requirements. No readiness state proves their authorization. UI Automation, lock state, usbmuxd reachability, and actual UI effects are not checked.

The user's selected physical test device is an iPhone 13 mini. Its observed disabled-mode/absent-image state and blocked recording check are recorded in [verification](VERIFICATION.md); private identifiers and raw device output remain under ignored `tmp/`.
