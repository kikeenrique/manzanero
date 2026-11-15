# Simulator input and accessibility

Simulator trees, element actions, waits, single-contact touch, Home and lock, named keys and US-layout typing run in the `manzanero` process against Apple frameworks. No helper executable, Simulator.app window or permission is needed. The design and the experiments behind it are in [the research](simulator-input-research.md); live results are in [verification](verification.md#simulator-input-and-accessibility).

## Commands

```sh
manzanero simulator <UUID> tree [pid]
manzanero simulator <UUID> press-id|press-label [pid] <exact-selector>
manzanero simulator <UUID> scroll-id|scroll-label [pid] <exact-selector>
manzanero simulator <UUID> wait-id|wait-label [pid] <exact-selector> [--until …] [--value …] [--timeout …] [--interval …]
manzanero simulator <UUID> tap <x> <y>
manzanero simulator <UUID> long-press <x> <y> <seconds>
manzanero simulator <UUID> swipe|drag <x1> <y1> <x2> <y2> <seconds>
manzanero simulator <UUID> button home|lock
manzanero simulator <UUID> key return|escape|backspace|tab|space|up|down|left|right
manzanero simulator <UUID> type <text>
```

Arguments, ranges, coordinate space (normalized `0...1`, origin top left), receipts, dry-run plans, exit codes and error categories are those of the physical commands in [physical input](native-input.md), [physical typing](physical-typing.md) and [native accessibility](direct-accessibility.md). The selectors, the press and scroll guards, the wait conditions and the tree JSON are the same code. Every command has a `--dry-run` plan that does not look the simulator up.

MCP tools take `platform: simulator` for the same operations: `get_ui_tree`, `press_element`, `scroll_to_element`, `wait_for_element`, `tap`, `drag`, `long_press`, `press_button`, `press_key`, `type_text` and `get_screen`. See [MCP](mcp.md).

## Requirements

- A booted simulator, addressed by its UUID (`manzanero devices simulators`). Names and `booted` are refused, because several simulators can match them. A simulator that is not `Booted` is refused with `device-not-ready` before any connection; `manzanero` never boots one implicitly.
- An Xcode whose CoreSimulator injects the `dtuhidd` HID daemon into the runtime (Xcode 27 on the tested machine). `doctor` reports `simulator-input` and `simulator-accessibility`; the daemon's launchd plist is checked by existence only.
- The developer directory comes from `DEVELOPER_DIR`, else `xcode-select -p`.

## How it works

**Input.** CoreSimulator's `-[SimDevice lookup:error:]` gives the Mach port of the simulator's `com.apple.coredevice.feature.remote.hid.digitizer`, `.keyboard` or `.button` service. libxpc's `xpc_endpoint_create_mach_port_4sim`, `xpc_connection_create_from_endpoint` and `xpc_connection_enable_sim2host_4sim` turn it into an XPC connection from the host. The connection carries the same `IndigoDigitizerEvent`, `IndigoKeyboardButtonEvent` and `IndigoButtonEvent` dictionaries the physical backend sends over RemoteXPC, built by the same functions and driven by the same schedulers (`ADCRunTouchSchedule`, `ADCRunKeyboardSchedule`, `ADCRunPress`). Each command waits for a readiness barrier (`{isBarrier: true}`, three seconds), sends the schedule, releases active contacts or keys if it is stopped, waits for a completion barrier, keeps the connection open for 380 ms and cancels it. The status contract is the physical one: a failure after input was attempted is `input-outcome-unknown` with `inputSent: possible`; a failure before is `transport-failed` with `inputSent: none`.

**Accessibility.** The tree, press, scroll and wait code sends the project's own `AccessibilityRequest` archives. The bridge unarchives each one with secure coding into AccessibilityPlatformTranslation's real `AXPTranslatorRequest`, sets client type 2 on hit tests, sends it with `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` and archives the `AXPTranslatorResponse` back. Swift decodes it with the physical data-only decoder and matching rules. Requests run one at a time with a five-second limit inside a 30-second session (a wait's session lasts its timeout plus 30 seconds).

Both routes are private interfaces of CoreSimulator, libxpc and AccessibilityPlatformTranslation and can change with any Xcode or macOS update. The sources are `Sources/AppleDeviceBridge/AppleSimulatorBridge.m`, `SimulatorAccessibilitySession.swift`, `SimulatorCommand.swift`, `DirectSimulatorInput.swift` and `SimulatorDevice.swift`.

## What differs from a physical device

| | Physical | Simulator |
| --- | --- | --- |
| Address | Hardware UDID or CoreDevice UUID, resolved through CoreDevice | Simulator UUID only |
| Preparation | Developer Mode, pairing, tunnel, awake unlocked display | `Booted` state; nothing else is checked |
| Display | Apple display JSON: backlight, geometry, orientation (`rot0` for AX) | CoreSimulator's main-screen size and scale; orientation is not read and reported as `portrait-assumed`; no backlight state |
| Foreground process | Hit test at the display centre | Frontmost-application request (type 4); when the simulator reports none, a hit test at the screen centre with client type 2. `application.selection` is `frontmost-or-centre-hit` and `foregroundSelection` counts which was used |
| AX carrier | Tunnel assertion, RSD directory, raw DTX, subscription enable/disable | One CoreSimulator request per call; no subscription (`cleanup.subscriptionStop: not-applicable`), no `connectionCleanup`, no `deviceAPIVersion` |
| Result keys | `backend: coredevice-direct`, `resolvedCoreDeviceUUID` | `backend: coresimulator-ax` or `coresimulator-dtuhid`, `resolvedSimulatorUUID`, `platform: simulator`, `screen` |
| Buttons | home, lock, volume-up, volume-down | home, lock; volume is refused as untested |
| Lease | Keyed by the CoreDevice UUID | Keyed by the simulator UUID |

The lease, the handoff pause and the CLI signal handling (SIGINT/SIGTERM exit 130/143 after attempted release) apply to simulator input exactly as to physical input; trees and waits take no lease and are not paused.

## Observed limits

- **Home Screen tree.** SpringBoard's full-depth snapshot came back empty after about three seconds; at depth 4 it took 0.39 s and at depth 10 2.0 s. A tree or wait on the Home Screen therefore fails with "the simulator returned no snapshot data". The lock screen's SpringBoard tree (105 nodes) was read. Presses and waits work in apps.
- **No frontmost application.** On the first boot the frontmost request answered within seconds; on a second fresh boot it answered with no application for at least 15 minutes, with the Home Screen, the probe app and Settings in front. The centre-hit fallback covers that case; a centre hit can select an overlay or embedded process, as on physical devices.
- **Visibility.** Settings' SwiftUI static texts inside a row report the native visibility attribute false while the row reports true. A wait for such a text times out as `not-visible`; select the row.

## Not implemented

- Unicode text entry (the AX set-value request, type 8 / attribute 53, works in experiments but has no command yet). `type` refuses non-ASCII text.
- Multi-contact input: `multi-tap`, two-path `multi-drag`, `pinch` and `gesture` are refused with `unsupported-operation`. Two contacts arrived in the research's raw experiment; Universal HID for three to five has not been tried.
- Rotation, landscape and iPad geometry, `paste`, `wake`, volume buttons.
- tvOS, watchOS and visionOS simulators, and runtimes or Xcodes other than the tested ones.

`screen` on a simulator prefers the tree, then OCR, like physical `screen`.
