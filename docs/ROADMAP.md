# appledevicescmd implementation scope

Build a Swift CLI providing proprietary device-control tooling's device capabilities, with a shared core that can also expose MCP. The implementation must use independently written code or appropriately licensed dependencies; the inspected commercial app is research evidence only.

## Required capability tracks

- Device discovery, pairing readiness and useful diagnostics over USB and Wi-Fi.
- Physical iPhone/iPad and simulator backends; Android scope awaits user preference.
- Screenshots, recording and a headless stream/session lifecycle.
- Touch, swipe, drag, multitouch, keyboard and hardware buttons.
- Accessibility hierarchy, stable element references, text matching and optional OCR fallback.
- App listing, installation, launch, termination, removal and container transfer.
- Crash reports and device logs.
- Appearance, accessibility settings, orientation and location simulation where supported.
- Build/install/launch orchestration with explicit project, scheme and device selection.
- Agent handoff and machine-readable errors/capabilities.
- Optional MCP interface sharing the CLI's operations.

## Backend plan and open decisions

Use Xcode's devicectl and simctl for operations they expose. CoreDevice remote HID and accessibility need additional investigation and implementation; discovery alone does not establish control. Keep private interfaces behind a backend boundary and report unsupported OS/service combinations explicitly. The user permits open-source third-party backends such as idevice; its existing C bindings at the inspected revision do not expose HID, so a small bridge may be needed. No proprietary binary is a runtime dependency.

The CLI provides JSON device discovery, diagnostics, physical/simulator app listing, installation, launch, removal, and screenshots. Simulator lifecycle, app termination, and URL opening are also exposed. A native Swift Vision image OCR command is implemented and builds, but its initial runtime check failed during pixel-buffer creation. Dry-run command planning is verified; live device integration remains unverified. An optional AXe simulator backend now exposes accessibility trees and input commands. A live tree → selector tap → tree check is verified; the remaining input commands have planner checks only. Physical HID now has an optional source-built idevice dependency with HID surface discovery, taps, simultaneous multitouch taps, drag/swipe, buttons, and keyboard keys. Build and parsing checks pass, but the currently discovered phone is absent from usbmuxd, so live input remains unverified. CoreDevice-only remote pairing/Wi-Fi transport, physical accessibility, text entry, moving multitouch gestures, streaming capture, file transfers, logs, settings, build orchestration, and MCP remain outstanding. Full parity remains unimplemented. Physical-device and simulator integration must be verified outside this session's service restrictions if they remain inaccessible here.

Dependency details, pinned revisions, and build instructions are in [DEPENDENCIES.md](DEPENDENCIES.md).
