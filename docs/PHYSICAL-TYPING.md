# Experimental physical typing

```sh
appledevicescmd physical <UDID> type 'Hello, world!'
appledevicescmd --pairing-file tmp/phone.pairing.plist physical <UDID> type 'Hello!'
appledevicescmd --dry-run physical <UDID> type 'Hello!'
```

This path accepts 1...512 printable US-layout ASCII characters, tab, and LF newline. It rejects empty text, Unicode, carriage return, other control characters, and over-limit input before connecting. Newline generates Return and tab generates Tab. Text remains one literal subprocess argument, including leading dashes and shell-sensitive characters.

The phone's hardware-keyboard layout must match the US mapping. Caps Lock, input methods, focus, app behavior, and device state can change the resulting text. No echo comparison or physical UI check is implemented. This is partial text-entry support; it does not complete Unicode or physical keyboard parity.

MCP `type_text` accepts optional `platform: "physical"` and an optional existing `pairing_file` path. Omitting `platform` retains the simulator/AXe behavior for existing clients. The tool returns the usual dispatch receipt with `verified: false`; it does not return the supplied text. The CLI's physical Developer Mode preflight applies to typing.

## Backend lifecycle

The pinned idevice [HID implementation](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/core_device/hid.rs) exposes an owned `MainKeyboardService`. After the existing display-stream authentication setup, the bridge:

1. Creates a virtual keyboard through the library's identity-confirming constructor.
2. Maps ASCII to HID Keyboard/Keypad usages. Shifted characters send Left Shift and their key together.
3. Sends an empty pressed-key set after each character, releasing Shift as well as the character key. Each press/release phase has a 5 ms delay.
4. Attempts reset/removal of its owned keyboard after normal completion or dispatch failure, using the library's removal/absence check. It then follows the existing media-stream cleanup path.

The usage values were checked against Apple's installed `IOHIDUsageTables.h` in Xcode 27.2. These values and the library's private device protocol are different evidence sources: SDK constants do not establish device-side authorization or delivery.

Dispatch has a 30-second local deadline; keyboard removal has a separate 3-second deadline. Cleanup failure prevents success, and combined dispatch/cleanup failures preserve both diagnostics. The bridge's outer 60-second operation deadline can interrupt either phase. Dropped futures, abrupt process termination, outer timeout, and device disconnection can bypass completion of asynchronous cleanup; no removal guarantee is made for those cases. Avoid simultaneous physical screen/input controllers, as described in [dependencies](DEPENDENCIES.md).

## Verification

Swift planner/MCP tests cover validation, literal arguments, pairing routing, and disabled-Developer-Mode gating. Rust tests cover ASCII mappings, Shift release, stopping after failed press/release, removal attempts, cleanup failures, and dispatch/cleanup timeouts with synthetic keyboard mocks. These mocks test the bridge's lifecycle calls, not live HID wire behavior.

The iPhone 13 mini now reports Developer Mode enabled, and read-only bridge HID discovery succeeded over USB. No text was sent to it. Virtual-keyboard registration/removal and actual text output remain unverified on hardware. See [verification records](VERIFICATION.md).
