# Simulator input and accessibility

Simulator trees, element actions, waits, touch with one to five contacts and timed gesture sequences, Home and lock, named keys, US-layout typing and Unicode entry by accessibility set-value run in the `manzanero` process against Apple frameworks. No helper executable, Simulator.app window or permission is needed. The design and the experiments behind it are in [the research](simulator-input-research.md); live results are in [verification](verification.md#simulator-input-and-accessibility).

## Commands

```sh
manzanero simulator <UUID> tree [pid]
manzanero simulator <UUID> press-id|press-label [pid] <exact-selector>
manzanero simulator <UUID> scroll-id|scroll-label [pid] <exact-selector>
manzanero simulator <UUID> set-value-id|set-value-label [pid] <exact-selector> <text>
manzanero simulator <UUID> wait-id|wait-label [pid] <exact-selector> [--until …] [--value …] [--timeout …] [--interval …]
manzanero simulator <UUID> tap <x> <y>
manzanero simulator <UUID> long-press <x> <y> <seconds>
manzanero simulator <UUID> swipe|drag <x1> <y1> <x2> <y2> <seconds>
manzanero simulator <UUID> pinch <center-x> <center-y> <start-span> <end-span> <seconds>
manzanero simulator <UUID> multi-drag <seconds> <x1> <y1> <x2> <y2> ...   # two to five paths
manzanero simulator <UUID> multi-tap <x1> <y1> <x2> <y2> ...                # two to five contacts
manzanero simulator <UUID> gesture '<JSON frames>'
manzanero simulator <UUID> button home|lock
manzanero simulator <UUID> key return|escape|backspace|tab|space|up|down|left|right
manzanero simulator <UUID> type <text>
```

Arguments, ranges, coordinate space (normalized `0...1`, origin top left), receipts, dry-run plans, exit codes and error categories are those of the physical commands in [physical input](native-input.md), [physical typing](physical-typing.md) and [native accessibility](direct-accessibility.md). The selectors, the press and scroll guards, the wait conditions and the tree JSON are the same code. Every command has a `--dry-run` plan that does not look the simulator up.

MCP tools take `platform: simulator` for the same operations: `get_ui_tree`, `press_element`, `scroll_to_element`, `wait_for_element`, `set_element_value`, `tap`, `drag`, `long_press`, `pinch`, `multi_drag`, `multi_tap`, `perform_gesture`, `press_button`, `press_key`, `type_text` and `get_screen`. See [MCP](mcp.md).

## Unicode text: set-value

`set-value-id` and `set-value-label` replace one element's whole value with any Unicode text (1...65536 UTF-8 bytes, no NUL) through the accessibility set-value request (request type 8, attribute 53, parameter `value`). No key event, keyboard layout or clipboard is involved. Selection and guards are those of `press-id`/`press-label`: foreground selection, two fresh unique snapshots, live enabled and visible state and frame, an exact centre hit and application/display rechecks. Before the request the element must answer the settable query (type 3, attribute 53) with true; otherwise the command fails as `ambiguous-or-missing-target` and sends nothing, so select the text field itself, not its label. Afterwards the value is read back once: the receipt has `status: acknowledged`, `valueMatches` (true, false, or null with `readBackFailure`) and the requested and read-back byte counts. An app may transform the value, so a mismatch is reported rather than treated as failure. The command takes the device lease like a press. A failure after the request was sent is `input-outcome-unknown`.

Observed on the probe's text field: the field becomes first responder, as after a tap. With an on-screen keyboard that can cover a field low on the screen, and a covered field reports itself not visible, so a second set-value is refused by the visibility guard until the keyboard is dismissed.

**Physical devices refuse it** (`unsupported-operation`): the same requests would travel over the physical DTX route, but they have never been sent to a phone.

**Why `type` stays ASCII.** `type` sends HID key events to whatever has focus, at the caret, in the US layout. Set-value targets a named element and replaces its whole value. Falling back from one to the other for non-ASCII text would change both the target and the effect without the caller asking, so `type` refuses non-ASCII text and its message points to set-value.

**Why `paste` is refused.** Paste on a phone writes the clipboard, then sends Command+V. On the simulator the clipboard write is the problem: `simctl pbcopy` exited 0 three times out of three, but `simctl pbpaste` then returned other text that was already on the simulator's pasteboard, not the copied text, and `pbinfo` listed an item carrying the type `com.apple.coredevice.dtpasteboardd.sync` with promised data (the research saw an empty pasteboard instead). A paste could therefore insert text the caller never supplied. `paste` is refused with a pointer to set-value. The CoreDevice pasteboard service inside the simulator (`dtpasteboardd`) was not tried.

## Requirements

- A booted simulator, addressed by its UUID (`manzanero devices simulators`). Names and `booted` are refused, because several simulators can match them. A simulator that is not `Booted` is refused with `device-not-ready` before any connection; `manzanero` never boots one implicitly.
- An Xcode whose CoreSimulator injects the `dtuhidd` HID daemon into the runtime (Xcode 27 on the tested machine). `doctor` reports `simulator-input` and `simulator-accessibility`; the launchd plists of `dtuhidd` and `dtdeviceinfod` (display information) are checked by existence only.
- The developer directory comes from `DEVELOPER_DIR`, else `xcode-select -p`.

## How it works

**Input.** CoreSimulator's `-[SimDevice lookup:error:]` gives the Mach port of the simulator's `com.apple.coredevice.feature.remote.hid.digitizer`, `.keyboard` or `.button` service. libxpc's `xpc_endpoint_create_mach_port_4sim`, `xpc_connection_create_from_endpoint` and `xpc_connection_enable_sim2host_4sim` turn it into an XPC connection from the host. The connection carries the same `IndigoDigitizerEvent`, `IndigoKeyboardButtonEvent` and `IndigoButtonEvent` dictionaries the physical backend sends over RemoteXPC, built by the same functions and driven by the same schedulers (`ADCRunTouchSchedule`, `ADCRunKeyboardSchedule`, `ADCRunPress`). Each command waits for a readiness barrier (`{isBarrier: true}`, three seconds), sends the schedule, releases active contacts or keys if it is stopped, waits for a completion barrier, keeps the connection open for 380 ms and cancels it. The status contract is the physical one: a failure after input was attempted is `input-outcome-unknown` with `inputSent: possible`; a failure before is `transport-failed` with `inputSent: none`.

**Several contacts.** As on a phone, `pinch` and two-path `multi-drag` send both contacts in each Indigo digitizer event (`pointOne`, `pointTwo`), with the same refusal of overlapping or crossing paths (checked before the simulator is looked up). `multi-tap`, `multi-drag` with three to five paths and `gesture` build the physical complete-state schedule (`DirectPhysicalGesture`, `NativeGestureSequence`) and send its 58-byte reports to the simulator's `com.apple.coredevice.feature.remote.universalhidservice`, the same `Request`/`send` messages the phone's Universal HID service takes. The simulator's service lists one touchscreen per display (observed: the primary display and a "Resizable" one, plus keyboard, buttons and other services); only the primary display's touchscreen delivers to the app, so the touchscreen is chosen by the primary display's unique identifier, which comes from the simulator's display information (`com.apple.coredevice.feature.getdisplayinfo` in `dtdeviceinfod`, a CoreDevice action request answered in the same shape as `devicectl device info displays`). The display information is read twice around planning, as on a phone: an off display is refused as `display-off` and a change between the reads as `precondition-changed`.

**Orientation, landscape and iPad.** Measured on an iPhone 17e and an iPad mini (A17 Pro) simulator ([verification](verification.md#rotation-and-ipad-on-the-simulator)):

- The display information reports the primary display's `nativeOrientation` (`rot0` on both models) and `currentOrientation`, which follows the interface: `rot270` for the device turned landscape left, `rot90` for landscape right, `rot180` upside down on the iPad. On the iPhone, whose apps do not turn upside down, the interface stayed `rot90` with the device upside down, as on a phone.
- The digitizer (Indigo) and Universal HID take **portrait-native** coordinates in every orientation, as a phone does: a raw digitizer point (0.2, 0.3) sent in landscape left landed at (0.3, 0.8) of the landscape interface. Simulator touch therefore reads the display information twice around planning, exactly like `DirectPhysicalTouch` and `DirectPhysicalGesture`, and rotates the normalized current-interface coordinates with the physical `DirectTouchDisplay.portrait`. Touch on a dark display is refused as `display-off`, as on a phone.
- Accessibility frames in the tree are **interface** points (the summary readout of the probe at (16, 64, 812 × 92) in landscape), but hit tests take **native** points: at the interface centre of the probe's reset box a hit test failed with error 8 until the point was mapped to native portrait points. The simulator AX display is therefore the interface (844 × 390 on the iPhone in landscape, `orientation: rot90|rot270`), and every hit point, including the centre fallback for foreground selection and the press guard's exact hit, is mapped to native points with the same rotation. Trees and waits do not need an awake display.
- Results carry `screen.orientation` (`rot0`…`rot270`), `interfaceWidthPoints` and `interfaceHeightPoints` beside the native `widthPoints`/`heightPoints`; touch receipts add `displayRotationDegrees` as on a phone. Buttons, keys and typing do not read the orientation (`screen.orientation: not-read`).
- Orientation can be changed without Simulator.app through the simulator's `com.apple.coredevice.feature.remote.devicecontrol.orientation` service (`dthidd`): a request `{messageType: Request, payload: {changeOrientation: {_0: "landscapeLeft"}}}` turned the device, and `currentOrientation` asked for the state. Manzanero does not send it; it was used only for the measurements.

**Accessibility.** The tree, press, scroll and wait code sends the project's own `AccessibilityRequest` archives. The bridge unarchives each one with secure coding into AccessibilityPlatformTranslation's real `AXPTranslatorRequest`, sets client type 2 on hit tests, sends it with `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` and archives the `AXPTranslatorResponse` back. Swift decodes it with the physical data-only decoder and matching rules. Requests run one at a time with a five-second limit inside a 30-second session (a wait's session lasts its timeout plus 30 seconds).

Both routes are private interfaces of CoreSimulator, libxpc and AccessibilityPlatformTranslation and can change with any Xcode or macOS update. The sources are `Sources/AppleDeviceBridge/AppleSimulatorBridge.m`, `SimulatorAccessibilitySession.swift`, `SimulatorCommand.swift`, `DirectSimulatorInput.swift` and `SimulatorDevice.swift`.

## What differs from a physical device

| | Physical | Simulator |
| --- | --- | --- |
| Address | Hardware UDID or CoreDevice UUID, resolved through CoreDevice | Simulator UUID only |
| Preparation | Developer Mode, pairing, tunnel, awake unlocked display | `Booted` state; nothing else is checked |
| Display | Apple display JSON: backlight, geometry, orientation (`rot0` for AX) | CoreSimulator's main-screen size and scale, plus the same display JSON from the simulator's `dtdeviceinfod`: backlight and orientation for touch, any orientation for AX (interface frames, native hit points) |
| Foreground process | Hit test at the display centre | Frontmost-application request (type 4); when the simulator reports none, a hit test at the screen centre with client type 2. `application.selection` is `frontmost-or-centre-hit` and `foregroundSelection` counts which was used |
| AX carrier | Tunnel assertion, RSD directory, raw DTX, subscription enable/disable | One CoreSimulator request per call; no subscription (`cleanup.subscriptionStop: not-applicable`), no `connectionCleanup`, no `deviceAPIVersion` |
| Result keys | `backend: coredevice-direct`, `resolvedCoreDeviceUUID` | `backend: coresimulator-ax` or `coresimulator-dtuhid`, `resolvedSimulatorUUID`, `platform: simulator`, `screen` |
| Buttons | home, lock, volume-up, volume-down | home, lock; volume is refused as untested |
| Lease | Keyed by the CoreDevice UUID | Keyed by the simulator UUID |

The lease, the handoff pause and the CLI signal handling (SIGINT/SIGTERM exit 130/143 after attempted release) apply to simulator input exactly as to physical input; trees and waits take no lease and are not paused.

## Observed limits

- **Home Screen tree.** SpringBoard's full-depth snapshot came back empty after about three seconds; at depth 4 it took 0.39 s and at depth 10 2.0 s. A tree or wait on the Home Screen therefore fails with "the simulator returned no snapshot data". The lock screen's SpringBoard tree (105 nodes) was read. Presses and waits work in apps.
- **No frontmost application.** On the first boot the frontmost request answered within seconds; on a second fresh boot it answered with no application for at least 15 minutes, with the Home Screen, the probe app and Settings in front. The centre-hit fallback covers that case; a centre hit can select an overlay or embedded process, as on physical devices.
- **Snapshots that come back empty at once.** After the probe app's own XCUITest run on the simulator, every snapshot of the probe (and of the relaunched probe) came back empty within a millisecond, while application and frontmost requests answered; a reboot cleared it. In the first minute after that reboot a few snapshots also came back empty, then 20 of 20 trees in a row succeeded. Such a tree or action fails before sending anything; repeat it after inspecting.
- **A text field reported not visible in landscape.** In the probe's first landscape layouts, its text field lower on the screen (overlapping the area of the recent-gestures readout) reported the native visibility attribute false, so set-value refused it at the live-state guard; at the top of the screen it reported true and set-value worked. The cause was not isolated.
- **Visibility.** Settings' SwiftUI static texts inside a row report the native visibility attribute false while the row reports true. A wait for such a text times out as `not-visible`; select the row.

## Not implemented

- Non-ASCII `type` and `paste` (see [set-value](#unicode-text-set-value) for the reasons and the alternative).
- `wake`, volume buttons. Changing the orientation (a test turns the simulator itself).
- tvOS, watchOS and visionOS simulators, and runtimes or Xcodes other than the tested ones.

`screen` on a simulator prefers the tree, then OCR, like physical `screen`.
