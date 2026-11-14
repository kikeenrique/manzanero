# Physical-device readiness

```sh
manzanero physical <device> readiness
```

The CLI and MCP `device_readiness` return preparation information without input. There are two separate results: CoreDevice prerequisites at the top level and sequential UI observations under `ui`.

## CoreDevice status

| Status | Meaning |
| --- | --- |
| `blocked` | Developer Mode is explicitly disabled |
| `needsPreparation` | Developer Mode, pairing and connection are confirmed, but developer-image services are unavailable |
| `unknown` | Required information is missing/unrecognized or pairing/connection is not confirmed |
| `prerequisitesPresent` | Developer Mode, developer-image services, pairing and connection are reported present |

The command exits 0 only for `prerequisitesPresent`. Other states still return JSON with exit 1. MCP preserves the report under `structuredContent.result` and sets `isError: true` for the nonzero result.

This status does not verify UI Automation or successful input/capture. A prepared device can still have its display off.

The decoder prefers current `properties` fields and falls back to deprecated fields only when the current field is absent. Developer-image availability still needs a legacy fallback on the inspected Xcode; if that disappears without a recognized replacement, it becomes unknown.

## UI observations

Explicit readiness resolves one fresh CoreDevice UUID, then runs Apple's `device info displays` and `device info lockState`, each with a ten-second Apple-tool timeout. They are sequential, non-atomic observations that may change immediately.

| Field | Interpretation |
| --- | --- |
| `ui.displayPower` | `on`, `off` or `unknown`, from one recognized primary display |
| `ui.passcodeRequired` | Apple's Boolean field; omitted when unavailable/unrecognized |
| `ui.unlockedSinceBoot` | Apple's Boolean field; omitted when unavailable/unrecognized |
| `ui.status` | `needsUserAction`, `unknown` or `observed` |
| `ui.actions`, `ui.diagnostics`, `ui.limitations` | Preparation steps and uncertainty |

`observed` is not “ready.” `passcodeRequired: false` and `unlockedSinceBoot: true` do not prove that the current UI is unlocked. These fields do not detect the Enable UI Automation switch.

Lock-state identity must match the resolved UUID. Display responses without an identity field remain associated with the explicit query target. Wrong identities, malformed Booleans, ambiguous displays, oversized data or query failure stay unknown; raw Apple error payloads are not copied into diagnostics. Cancellation propagates.

The top-level exit/status remains CoreDevice-only. For example, `status: prerequisitesPresent` can coexist with `ui.status: needsUserAction` and an action to wake the device.

## Preparing the device

For disabled Developer Mode, open **Settings → Privacy & Security → Developer Mode**, enable it, restart, unlock and confirm **Turn On**. Let the selected Xcode prepare developer support, then query readiness again.

For UI work, keep the device awake/unlocked and enable **Settings → Developer → Enable UI Automation**. The CLI does not enable settings, establish trust, enter passcodes or wake/unlock automatically.

## Automatic operation preflight

Developer operations query the details-based prerequisites before dispatch. Known disabled Developer Mode stops those operations with guidance. Unknown state or unavailable/unknown developer-image services produces a diagnostic and lets the selected backend enforce its own requirements; some Apple operations can prepare support automatically.

Ordinary preflight does not run the additional UI queries. App listing/install/uninstall, raw container operations, reports and logs have their own service requirements and are not uniformly blocked by this preflight.

Dry runs query nothing. No readiness result proves authorization for every service.

## Validation

```sh
mise run test:mcp-readiness <hardware-UDID>
```

This reads state through real MCP without input. The latest iPhone 13 mini check reported CoreDevice prerequisites present and display off, with no passcode requirement reported. It did not establish current UI unlock or a successful wake. See [verification](VERIFICATION.md).
