# Scope, feature sources, and implementation status

**Current architecture constraint:** device operations may use this project's in-process Apple framework/API implementations or Apple executables, never non-Apple helper binaries. Direct physical buttons and single-contact touch are available; legacy ipb/idevice/AXe paths are disabled pending remaining migration. Feature evidence below involving those paths is historical. See [current runtime availability](PARITY-STATUS.md#current-runtime-availability).

The user's objective is a Swift CLI named `appledevicescmd` with proprietary device-control tooling's device features, using the same kinds of Apple frameworks/APIs or permitted third-party tools, with optional MCP sharing the operations. This is not yet a complete clone.

This roadmap is an implementation inventory, not a claim that the user explicitly approved each inferred item. Vendor documentation was rechecked on **2026-11-11**. Current public documentation and the inspected device-control tooling 0.9.0/build 90 artifact are different evidence sources; current pages do not establish which release introduced a feature.

The implementation inventory includes the completed report/log command work described in [verification records](VERIFICATION.md). Earlier review findings describe their own revision; they do not supersede newer verification entries.

## Explicit user requirements

- Swift CLI named `appledevicescmd`.
- Apple-device feature parity using Apple interfaces and permitted open-source dependencies such as idevice.
- All Apple device families are in scope, explicitly including iPhones, iPads, Apple Watches, Apple TVs, and the user's Duo targets. Device-family support needs its own implementation and verification; iPhone evidence does not prove another family's behavior.
- Android devices/emulators are explicitly excluded by the user and are not parity requirements.
- Optional MCP support based on the same operations.
- Commit verified tasks separately; keep research and verification in `docs/` and temporary artifacts in `tmp/`.
- Use mise tasks instead of the former Python build helper.

The main executable is Swift. Physical HID, AX and media negotiation use project-owned Swift logic and a linked Objective-C interoperability target calling Apple interfaces in process. The former Rust device bridge remains disabled as a migration reference. Native HEVC frames, short CLI/MCP movies and a 35-second CLI HEVC capture have iPhone 13 mini verification with scoped cleanup. RTCP receiver reports are implemented; reliable startup, keyframe/crash recovery and captures beyond verified durations remain incomplete or unverified.

## Parity inventory and explicit platform scope

| Capability | Source | Current implementation and evidence |
| --- | --- | --- |
| iPhone/iPad over USB and Wi-Fi | [Device setup]([private reference removed]) | CoreDevice discovery, an optional native Apple framework input helper, and an optional usbmuxd/independent Wi-Fi protocol path. Native Home/tap/drag and protocol-based AX reads/selector presses have scoped verification on the USB iPhone 13 mini. Idevice HID input effects and Wi-Fi pairing remain unverified. |
| iOS simulators | [Vendor overview]([private reference removed]) | simctl operations and optional AXe input/tree backend. A tree → Settings label tap → tree flow is verified live. |
| Apple Watch and watch simulators | [Apple Watch]([private reference removed]) | No dedicated support or verification yet. Backend tools accepting a watch identifier do not establish feature parity. |
| iPad-specific behavior | Explicit user requirement | Generic iPhone/iPad command paths exist, but no dedicated physical iPad evidence or multitasking/display verification yet. |
| Apple TV / tvOS | Explicit user requirement | No dedicated control implementation or verification yet. |
| Duo targets | Explicit user requirement | Dedicated device/posture/display coverage is not implemented or verified. Generic device-ID acceptance does not establish support. |
| Screen mirroring and recordings | [Vendor overview]([private reference removed]) | Simulator recording remains available. Native physical recording uses Apple negotiation, HEVC RTP/VideoToolbox and AVFoundation, with receiver reports. Two-second CLI/MCP and 35-second CLI HEVC movies have iPhone 13 mini verification with owned cleanup. Startup, keyframe/crash recovery, mirroring and captures beyond verified durations remain incomplete/unverified. The phone rejects default devicectl recording. See [recording contract and media inspection](RECORDING.md). |
| Touch, pinch, keyboard, hardware buttons | [Control]([private reference removed]) | Native physical Home/tap/drag, long-press, two-contact Maps zoom through pinch/multi-drag, Unicode clipboard paste, and Backspace have scoped verification on the USB iPhone 13 mini through an explicit [CoreDevice backend](NATIVE-INPUT.md). Bounded [timed touch sequences](GESTURE-SEQUENCES.md) now support sampled paths, holds, repeated taps, and independent contact arrivals/lifts; a one-contact sampled swipe has physical navigation evidence. Simulator input and experimental idevice multitap, multicontact movement, pinch, keys, and ASCII typing also exist. Simulator pinch remains missing; independently timed multi-contact effects, three-to-five-contact effects, idevice effects/layout/cleanup, hardware failure cleanup, and other native keys/buttons remain unverified. See [multitouch](MULTITOUCH.md) and [typing limits](PHYSICAL-TYPING.md). |
| Agent screen understanding and text targeting | [MCP]([private reference removed]), [static investigation](ANALYSIS.md) | AXe simulator tree/selectors and unified screenshot inspection with OCR fallback, verified on a simulator fixture. Explicit-PID and primary-display-centre selected physical AX trees are verified in Settings through CLI and real MCP on the USB iPhone 13 mini. Physical screen auto returned accessibility data and inline PNG through MCP. Fresh exact identifier/label AX presses, with and without PID, have screenshot-verified Settings navigation, with unique target, live state, hit, and portrait display guards. Stable actionable references, broader AX actions/coverage, and physical OCR verification remain open. Raw callback capture/cleanup and offline decoding are also verified. See [screen inspection](SCREEN-UNDERSTANDING.md) and [accessibility evidence](ACCESSIBILITY-PROTOCOL.md). |
| App management and development app data | [Apps]([private reference removed]) | App list/install/launch/uninstall, physical termination by PID and URL opening, plus app-container listing and raw pull/push command plans. Simulator termination uses a bundle ID. Physical details, launching Settings, and an underlying temporary-domain copy round trip are verified; other physical app mutations and app-container permissions remain unverified. Xcode-format export/replacement is missing. |
| Saved crash reports, spins, logs, and diagnostics | [Reports]([private reference removed]) | Xcode-backed `reports` listing and `report` download. Listing verified on a physical phone; downloads unverified. Parsing, symbolication, type filters, and deletion remain missing. Vendor parity includes listing/reading saved reports and saving/deleting them; the source page does not establish continuous live OS log streaming. |
| Build and launch from source | [Build & Run]([private reference removed]) | Swift `build-run` orchestrates Xcode build/settings, app selection/validation, installation, and restart. Simulator project/Debug and workspace/Release flows verified; physical signing/deployment unverified. Automatic scheme discovery, progress, cancellation, and crash/source integration remain missing. See [CLI contract](BUILD-RUN.md). |
| Human handoff | [Human Handoff]([private reference removed]) | Explicit terminal and MCP form requests, completion outcomes, and same-process device mutation pause. Synthetic terminal/stdio form exchanges verified. Automatic prompt detection, native notifications, and mirror banners are missing; acknowledgement does not verify the device step. See [handoff contract](HANDOFF.md). |
| Multiple devices, agent activity, approvals | [Overview]([private reference removed]), [MCP]([private reference removed]) | Explicit per-command targets exist. Coordinated sessions, activity tracking, and an application approval policy are missing. CLI dry-run is not an approval system. |
| MCP interface | [Vendor MCP]([private reference removed]); optional in the user's request | `mcp` serves 33 tools over stdio through the official Swift SDK and the CLI's shared command service, including native long-press/timed sequences, physical AX press/scroll-to-visible, Unicode paste, screen/archive inspection, coordinated gestures, and form-based handoff when supported by the host. Supports protocol versions through 2025-11-25. No HTTP, built-in approval policy, general progress, or general cancellation coordination. Backend feature/verification gaps remain. See [MCP contract](MCP.md). |

Physical native scroll-to-visible now supports exact identifier/label selection for targets already present in the bounded AX snapshot, with fresh state/display guards and a separate post-action visibility/frame/hit observation. CLI movement and the real MCP already-visible native-false case have scoped Settings verification. Virtual-list discovery, broad app coverage, other orientations, and other device families remain open. See [scroll contract](ACCESSIBILITY-PROTOCOL.md#scroll-an-element-into-view).

Native long-press now reuses the pinned helper's held-touch operation with 0.1...10-second requested duration. CLI and real MCP each opened the Maps icon context menu on the selected iPhone 13 mini with a 0.8-second hold, independently screenshot-confirmed. Other targets/durations/orientations and failure release on hardware remain unverified. See [long-press contract](NATIVE-INPUT.md#long-press).

GUI windows, menus, and keyboard shortcuts need CLI equivalents where they express a device operation; recreating the vendor's Mac GUI is not part of a CLI deliverable.

## Proposed CLI engineering work and additional candidates

These items support the implementation or need further parity evidence. They are not all established vendor requirements:

- Consistent machine-readable errors, capability reporting, command deadlines, cancellation, and backend diagnostics. `doctor`, dry-run, and [physical readiness](READINESS.md) exist but do not cover these fully. Readiness reports Developer Mode/image state and stops known disabled-mode developer operations; it is not live capability verification.
- Filter physical discovery: `devices physical` currently forwards an unfiltered CoreDevice inventory that can include simulators.
- Stable snapshot references and ambiguity rules for selector targeting, including OCR targeting. Automatic OCR fallback exists; coordinate conversion and actionable text selectors remain missing. The exact reference format is a design choice, not an explicitly requested wire format.
- Appearance, accessibility settings, orientation, and simulated location. Static framework/API evidence makes these candidates; the exact supported vendor operations and CLI contract need a separate baseline.
- Per-device isolation and lifecycle for recording, streaming, and input sessions.
- Experimental finite `logs` capture through idevice's OS trace service is an additional diagnostic capability. Duration/entry/byte limits and error propagation are tested synthetically; live capture remains unverified. It does not replace saved-report parity.

No success criterion is satisfied merely by a successful build or a dry run. Live verification must cover the claimed device/platform/transport combination. No proprietary device-control tooling binary is a runtime dependency.

See [dependencies](DEPENDENCIES.md), [transport investigation](TRANSPORT.md), [accessibility protocol](ACCESSIBILITY-PROTOCOL.md), and [verification records](VERIFICATION.md).
