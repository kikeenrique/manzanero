# Folding the iPhone Duo simulator

> **Built (2026-11-16):** `fold`, `unfold` and `hinge <degrees>` use route 1 below, and `hinge` without an
> angle reads it through route 2 ([other families](other-families.md#fold-iphone-duo)). Touch, trees, actions and
> default captures follow the active display; the "Still unknown" questions about touch and AX on the inner display
> are answered in [the inner display](other-families.md#the-inner-display-unfolded).
>
> **Status (2026-11-16):** research pass, no product code changed. Follows up the "Fold state" section of
> [the other-families research](other-families-research.md#fold-state). **Result: a working route was found and
> exercised.** Folding, unfolding and reading the hinge angle all work from the host over the same `_4sim` XPC
> connections manzanero already uses, without any UI.

**[O]** observed (ran it, saw the result). **[I]** inferred (from strings, source or docs; not exercised here).
**[S]** read in another tool's source or in Apple's documentation (by the web research pass; not re-verified line by line).

## Environment

- Host macOS 27.2.1, Xcode 27.2 (27B52), CoreDevice 651.32.
- Simulator `manzanero-research-duo-fold`: iPhone Duo (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, `iPhone19,4`),
  runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4` (24B91016s). Booted headless with `simctl boot`;
  no Xcode, Device Hub or simulator UI was opened. Shut down at the end and left in place.
- Scratch material in `tmp/duo-fold/` (untracked): `fold.m` / `fold` (the probe), screenshots `s*.png`,
  `log-unfold.txt`, string dumps, `extract.c` (shared-cache extractor using Apple's `dsc_extractor.bundle`) and
  `dsc/` (3.3 GB of extracted simulator dylibs; safe to delete).

## Conclusion

1. **Fold/unfold:** send one `IndigoVendorDefinedEvent` to the simulator's
   `com.apple.coredevice.feature.remote.hid.vendordefined` service (published by the injected `dtuhidd`, the same
   daemon manzanero already drives for touch and keys). Payload: usage page `0xFF61`, usage `0x5B`, version `0`, and
   `data` = a binary `IOCFSerialize` of `{source: "hinge-slider-control", type: "range", value: <degrees 0…180>}`.
   This is the event Device Hub's hinge control sends. `0` is closed, `180` is fully open. [O]
2. **Read the angle:** CoreDevice action `com.apple.coredevice.action.streamhingeangle` on the simulator's
   `com.apple.coredevice.feature.monitormotion` service streams `{angle, mechanicalAngle, minAngle (0), maxAngle (180),
   velocity, isAngleValid, timestamp}` samples. [O]
3. **Read which display is live:** the existing `getdisplayinfo` reply. Unfolded: `LCD-1` `backlightState: activeOn`,
   `LCD` `off`, `currentDeviceOrientation: landscapeRight`, `LCD-1` `currentOrientation: rot90`. Folded: `LCD` `activeOn`,
   `LCD-1` `off`, `portrait`. The `primary` flag stays on `LCD` in both states. [O]
4. **What breaks in manzanero today when unfolded:** `tap` is refused (`The simulator's display is off …`) and `tree`
   fails (`semantic refusal … error 18`), because both follow the display marked `primary` (`LCD`), which is off.
   After folding again, `tree` worked at once. [O]

**Size of the work:** `fold`/`unfold` (and `hinge <degrees>`) commands are **small** — one new message builder in the
bridge next to the existing Indigo builders, one command, a dry-run plan, MCP mapping. A `hinge`/posture read is
**small to medium** (one CoreDevice streaming request; decoding `Measurement` and `Duration` values, see below).
Making `tap`/`tree`/`screen`/`screenshot` follow the **active** display instead of the `primary` flag is the
**medium** part: choose the display whose `backlightState` is `activeOn` (prefer integrated), use its geometry and
`rot90` orientation for coordinates, its `uniqueId` to pick the matching Universal HID touchscreen, and its screen ID
(`--display=3`) for `simctl io` captures. None of that inner-display touch/AX path was exercised yet.

## What other tools do [S]

All of these are implementation references only; none was installed or run.

| Tool | Fold? | Exact call |
| --- | --- | --- |
| idb (`meta/idb`, formerly facebook/idb) | yes | `idb hinge [angle]` (reads when no angle). `FBSimulatorControl/HID/SimulatorVendorHIDTransport.swift`, `.../CoreDevice/SimulatorHingeProtocol.swift`, `idb/cli/commands/hinge.py`. Same vendor event (route 1) and `monitormotion`/`streamhingeangle` read (route 2). |
| AXe (cameroncooke/AXe) v2.0.0 | yes | `axe hinge set <0…180\|closed\|tabletop\|open>`, `axe hinge read`, `axe displays`. `Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorHingeNative.swift`, `FBSimulatorHingeReader.swift`. XPC envelope `messageType=IndigoVendorDefinedEvent`, `featureIdentifier=<service>`, `isBarrier=false`, `payload={usagePage, usage, version, data}`; read side sends `CoreDevice.XPCMessageKey.cancellationRequested` to stop. |
| Appium XCUITest driver / WebDriverAgent | yes | `mobile: setSimulatedHingeAngle {angle}` (simulator only), `mobile: getSimulatedHingeAngle`; WDA `GET/POST /wda/device/hingeAngle`. `XCUIDevice+FBHinge.m` creates the same vendor event **inside the runner** with `IOHIDEventCreateVendorDefinedEvent(…, 0xff61, 0x5b, 0, …)` and `IOHIDEventSystemClientDispatchEvent`; reads with private `CMAngleManager`. Docs: appium-xcuitest-driver `docs/guides/duo.md`. |
| foldctl (tatsuz0u, archived) | yes | `foldctl <udid> --hinge closed\|half\|open\|0-180`; private CoreDevice Swift API (`VendorDefinedHIDCapability.send(usagePage:usage:version:data:)`, `MonitorMotionCapability.monitorHingeAngle`, `monitorDeviceMotionState()` whose `propertyB` is posture 1 closed / 2 partially open / 3 flat). |
| devicehubctl (ChrisThoma) | yes | `pose closed\|partial\|open` presses Device Hub's "Closed"/"Partially Open"/"Open" buttons with `AXUIElementPerformAction(…, "AXPress")`. `hinge <deg>` spawns an in-simulator helper (entitlement `com.apple.springboard.sbdisplay.service`) that calls SpringBoardServices `SBSDisplayToolServiceConnection -swapDisplayWithSettings:completionHandler:` on `com.apple.springboard.sbdisplay`; its notes say apps see `UIHingeInteraction` updates but CoreMotion's angle does not follow. |
| Maestro, XcodeBuildMCP, ios-simulator-mcp, fastlane snapshot | no | No hinge code found (Maestro issue #3617 open). |
| Others (code search only) | likely | serve-sim `fold <deg>`, patrol `simulator_hinge.dart`, go-ios, agent-device, expo `scripts/duo/hinge_helper.c` — all mention `hinge-slider-control`. |

Apple:

- **XCUITest:** `XCUIDevice.shared.hinge` → `XCUIHinge?`, with settable `angle: CGFloat` **in radians**; "Setting this
  property can cause the device to switch between displays." No fold/unfold method and no status. [S] Not found in
  this Xcode's XCUIAutomation/XCTAutomationSupport strings by a quick grep for `hinge`/`fold`, so either the symbol is
  Swift-mangled differently or the docs are ahead of the SDK; unverified. [O for the grep, I for the reason]
- **Apps:** `UIHingeInteraction` / `UIHinge` (`angle` in radians, `status`: `.unknown`, `.closed`, `.partiallyOpen`,
  `.fullyOpen`), iOS 27.1 — present in the SDK's `UIKit.framework/Headers/UIHinge.h` and `UIHingeInteraction.h`. [O]
  SwiftUI `onHingeChange` / `DeviceHingeContext`. [S]
- **Device Hub:** "Closed", "Partially Open", "Open" buttons; Option reveals a continuous slider (third-party claim). [S]
- `simctl` and `devicectl` have no fold, hinge or posture command. [O for `simctl`]

## What Apple's binaries expose

- **Device type profile:** two integrated displays (`LCD` screen 1, 1398 × 2034 px, `primary`; `LCD-1` screen 3,
  2007 × 2853 px, `primary-1`, native rotation 270) plus TVOut, CarPlay and `Resizable`. No hinge, fold or posture key in
  `profile.plist` or `capabilities.plist`. [O]
- **Simulator runtime shared cache** (extracted with Apple's `dsc_extractor.bundle`): [O for the strings, I for the roles]
  - IOKit/HID: `IOHIDEventCreateHingeAngleEvent`, `kIOHIDEventTypeHingeAngle`, `HIDEvent(HIDHingeAngleEventPrivate)`.
  - CoreMotion: `CLAngleNotifier` (`Skipping open for physical HID device on VM/Simulator`), `CMAngleManager`,
    `CMMagicPoseManager` (hinge state, tabletop pose, per-display orientation). The simulator's angle therefore does not
    come from a physical HID hinge sensor; the vendor event feeds locationd's device-state relay (log category
    `com.apple.locationd.Motion:DeviceState`, see below).
  - SpringBoardFoundation `SBFDevicePoseProvider` (consumes `CMAngleManager` and `CMMagicPoseManager`; boundaries
    `closedToPartiallyOpen…`, `openTransitionBeginBoundary`, `closeTransitionBeginBoundary`, autocompletion), and a
    debug `displayTool` state (`targetMode`, `targetHingePosition`, `lockedForTestingUntil`).
  - SpringBoard test automation: `_handleTestAutomationSetDevicePoseOverride:fromClient:`,
    `_handleTestAutomationGetDevicePose:fromClient:`, `_handleTestAutomationGetActiveDisplayWindowSceneDisplayIdentifier:`;
    client side `-[SBSSystemServiceClient setDevicePoseOverride:]` / `getDevicePose`. A second, in-guest route
    (needs a helper spawned with `simctl spawn` and private entitlements); not tried, not needed.
- **Host side:** CoreDevice names `com.apple.coredevice.feature.remote.hid.vendordefined` and logs
  `Queried motion capabilities for device %s: spatialOrientation=…, hingeAngle=…`. The earlier pass's
  "`Hinge angle monitoring is not available on this device`" is a CoreDevice message for devices without the
  capability, not a statement about the Duo simulator. [O for strings; I for the reading]

## Experiments

All with the throwaway probe `tmp/duo-fold/fold.m` (Foundation + IOKit, `-[SimDevice lookup:error:]` →
`xpc_endpoint_create_mach_port_4sim` → `xpc_connection_create_from_endpoint` → `xpc_connection_enable_sim2host_4sim`,
as in `tmp/other-families/probe.m`).

### Setting the hinge [O]

Message on `com.apple.coredevice.feature.remote.hid.vendordefined`, after a barrier (`{isBarrier: true}` with reply):

```
{ featureIdentifier: "com.apple.coredevice.feature.remote.hid.vendordefined",
  messageType: "IndigoVendorDefinedEvent", isBarrier: false,
  payload: { usagePage: 0xFF61 (uint64), usage: 0x5B (uint64), version: 0 (uint64),
             data: IOCFSerialize({source: "hinge-slider-control", type: "range", value: <NSNumber degrees>},
                                 kIOCFSerializeToBinary) } }    // 152 bytes with the optional provider key
```

- Sent fire-and-forget (`xpc_connection_send_message`). Sending it with a reply returns `Connection interrupted`
  although the event is applied, so the service does not reply to events. [O]
- The optional `provider: "com.apple.Virtualization.VirtualMachines"` key makes no difference; without it the hinge
  still went 0 → 180. [O]
- **The connection must stay open briefly after sending.** Cancelling immediately after the final barrier lost the
  event (angle stayed 0); keeping it open 50 ms, 100 ms, 300 ms or longer always applied it. [O] Cause not checked
  (likely the virtual service is torn down with the peer before `dtuhidd` dispatches). [I]
- The guest animates the change itself: one event 0 → 180 produced samples every 10 ms at 600 °/s, reaching 180 in
  about 0.3 s, independent of how long the host connection then stays open. [O]
- Orientation through the same event (`source: "orientation-picker-control"`, `type: "enum"`, `value: "landscape-left"`)
  did **not** change `currentDeviceOrientation` (stayed `portrait`, Settings in front, folded). [O] Not pursued.

### Reading the angle [O]

Request on `com.apple.coredevice.feature.monitormotion` (same envelope as `getdisplayinfo`:
`CoreDevice.featureIdentifier`, `CoreDevice.actionIdentifier = "com.apple.coredevice.action.streamhingeangle"`,
`CoreDevice.action = {}`, `CoreDevice.invocationIdentifier`, `CoreDevice.deviceIdentifier`,
`CoreDevice.CoreDeviceDDIProtocolVersion = 2`, `CoreDevice.coreDeviceVersion`), with

```
CoreDevice.input = {
  actualInput: {
    changeThreshold: { value: 0.5, unit: { symbol: "°", converter: { coefficient: 1.0, constant: 0.0 } } },
    updateInterval: [ 0 (int64), 100000000000000000 (uint64) ]   // Swift Duration: [high, low] attoseconds = 0.1 s
  },
  streamProxy: { sideChannel: <uuid> }
}
```

The decoding errors walked through the shape: a plain string unit fails (`Expected to decode UnitCodingKeys`), a unit
without `converter` fails (`Expected to find key converter.`), a double interval fails (`array required here`). [O]
Samples then arrive as connection events under `CoreDevice.XPCMessageKey.sideChannelStatus.pushing.elements[]`, each
with `angle`, `mechanicalAngle`, `minAngle`, `maxAngle`, `velocity` (each `{value, unit}`), `isAngleValid`,
`isVelocityValid` and `timestamp`. The first sample is the current state (after boot: `angle 0`, i.e. closed). [O]
`angle` and `mechanicalAngle` differ in motion and slightly at rest (mechanical 90 → angle 94.62). [O]

### Active display, folded vs unfolded [O]

| State | `LCD` (screen 1) | `LCD-1` (screen 3) | Device orientation | Capture |
| --- | --- | --- | --- | --- |
| Fresh boot, angle 0 | `activeOn`, `rot0` | `off` | `portrait` | `--display=1` 1398 × 2034 Home Screen |
| Hinge 180 | `off` | `activeOn`, `rot90` | `landscapeRight` | `--display=3` 2853 × 2007 (landscape) Home Screen; `--display=1` black |
| Settings, 180 | `off` | `activeOn` | `landscapeRight` | Settings in two-column layout on `LCD-1` |
| Back to 0 | `activeOn` | `off` | `portrait` | Settings continues on `LCD` (one column) |

`primary: true` stays on `LCD` throughout. The display swap has hysteresis and depends on the path, not just the final
angle [O]:

- 0 → 110, 0 → 120, 0 → 130, 0 → 150, 0 → 170 in one step: swapped to `LCD-1`.
- 0 → 45 → 70 → 110 in steps (2 s apart): stayed on `LCD` (twice).
- 180 → 90: stayed on `LCD-1` (three times). 180 → 60, 40, 20, 10: swapped back to `LCD`.
- One reading right after closing showed both integrated displays `activeOn`; three seconds later only `LCD`. [O]

So `fold` should send 0 and `unfold` 180, then wait until the display information shows the expected display
`activeOn` (and the other `off`) before reporting success; intermediate angles need calibration against
`SBFDevicePoseProvider`'s velocity-dependent boundaries before they are offered as postures. [I]

### SpringBoard log during an unfold [O]

`log show` in the simulator (`tmp/duo-fold/log-unfold.txt`): `dtuhidd` accepts a peer on
`com.apple.coredevice.feature.remote.hid.vendordefined.peer`; then SpringBoard logs
`[com.apple.locationd.Motion:DeviceState] Sending MagicPose event to client …`,
`Ambient magic pose event detected [… hingeState : PO …]`, `updateIdleTimerForReason:"Hinge Motion"`,
`SBHingeMotionUnintendedInteractionMonitor: …`, `hinge MOTION STARTED`, `Hinge progress enabled`.

### manzanero unchanged against the unfolded device [O]

- `launch com.apple.Preferences` worked (Settings appeared on `LCD-1`).
- `tree`: `Simulator tree failed: Invalid accessibility response: semantic refusal or notification in request response (error 18).`
- `tap 0.5 0.5`: `The simulator's display is off or its state is unknown … no input sent.`
- After folding back to 0, `tree` returned Settings at once.

## Still unknown

- Touch and AX on the inner display: which Universal HID touchscreen matches `LCD-1`, whether `rot90` maps like a
  rotated iPhone, and which display/scene the AX snapshot targets. Cheapest check: unfold, then send one digitizer
  event to each of the three touchscreens Universal HID lists and watch which lands on `LCD-1` (screenshot
  `--display=3`).
- A posture (closed / partially open / flat) read: idb and foldctl use a device-motion-state stream on the same
  CoreDevice service (`propertyB` = posture); its action identifier was not found in the host strings (it may live in
  the in-simulator `dtdeviceinfod`). The angle stream plus the display information already answer "folded or
  unfolded".
- Reliable thresholds for intermediate angles (see hysteresis above) and whether apps' `UIHinge.status` follows the
  same transitions.
- Whether `XCUIHinge` exists in this Xcode's SDK (documented by Apple, not found by a quick string grep).
