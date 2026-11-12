# Feature parity status

Checkpoint: direct Apple buttons and single-contact touch, 2026-11-12. Full device-control tooling parity is not complete. Verification is scoped to the device, screen, transport, and environment recorded in [VERIFICATION.md](VERIFICATION.md).

## Current runtime availability

| Area | Current state |
| --- | --- |
| Physical hardware buttons | Project-owned in-process Apple CoreDevice/RemoteXPC backend; Home screenshot-verified through CLI. Other buttons and interruption cleanup need coverage. |
| Apple Xcode operations | Inventory, readiness, app/file/report operations, screenshots, simulator recording and Build & Run retain their existing implementation and verification limits. |
| Vision OCR / AVFoundation encoding | In-process Apple frameworks remain available. |
| Physical single-contact touch | In-process Apple digitizer implementation for tap, long-press, drag and swipe. Settings tap/drag and Maps long-press screenshot-verified on USB iPhone 13 mini. Other orientations/families and failure release unverified. |
| Physical two-contact movement | Direct spread/inward pinch visibly zoomed Maps through CLI and real MCP on USB iPhone 13 mini. Two-path multi-drag implemented/unit-tested; general independent paths, other orientations/families and failure release still unverified. |
| Physical named keys | Direct in-process implementation for return, escape, backspace, tab, space and arrows. Backspace has scoped Settings search verification; other keys remain hardware-unverified. |
| Physical three-to-five-contact/timed gestures, multi-tap, arbitrary typing and paste | Unavailable pending direct implementation; no ipb/idevice helper fallback. |
| Physical accessibility | Rust idevice executable blocked; direct replacement pending. Screen auto can fall back to Vision OCR. |
| Native physical recording | ipb video executable blocked; direct replacement pending. Default devicectl remains unsupported on the tested phone. |
| Simulator input/accessibility | AXe executable blocked; direct replacement pending. |
| CLI/MCP | Both enforce the same restriction. Full Apple-family scope remains unchanged. |

## Historical feature inventory

The inventory below records the implementations and scoped verification **before the non-Apple executable restriction**. Entries involving ipb, idevice or AXe do not mean those paths remain available. Use the current availability table above for execution status; preserve these observations as migration acceptance targets.

Scope clarification: all Apple device families are in scope, explicitly including iPhone, iPad, Apple Watch, Apple TV, and Duo targets. Android is excluded and is not an unfinished requirement. The same physical iPhone result cannot verify another device family.

**Verified** means a scoped live result was observed. **Implemented, unverified** means code exists without sufficient live proof. **Partial** means important functionality or coverage remains missing. **Missing** means there is no product implementation. **In progress** means current work has not reached a verified, committed checkpoint. Passing tests alone does not establish hardware behavior.

| Category | Feature | Status | Evidence or remaining gap |
| --- | --- | --- | --- |
| Devices | iPhone USB discovery/readiness | Partial, scoped verification | CoreDevice details and Developer Mode/image checks work; physical inventory can include simulators. |
| Devices | Wi-Fi pairing/reconnection | Implemented, unverified | Independent pairing/tunnel path exists; hardware pairing/reconnection/input proof remains missing. |
| Physical control | Home, tap, drag | Verified | Native CoreDevice backend on iPhone 13 mini over USB. Other buttons/orientations remain unverified. |
| Physical control | Long-press | Partial, scoped verification | Native 0.8-second hold opened the Maps Home Screen context menu on iPhone 13 mini. Other targets/durations/orientations and failure release on hardware remain unverified. |
| Physical control | Pinch and moving multitouch | Partial, scoped verification | Native two-contact Maps zoom in/out verified. Three-to-five-contact effects and failure cleanup on hardware remain unverified. |
| Physical control | Timed paths and repeated taps | Partial, scoped verification | Native complete-state sequences implemented with one to five slots, nonuniform times, arrivals/lifts, and release attempts. One-contact sampled swipe changed Home to App Library; real MCP double-tap zoomed Maps. Independent multi-contact timing and failure release need hardware coverage. |
| Physical control | Unicode paste / Backspace | Verified | Settings search insertion/removal observed. Paste explicitly replaces the phone clipboard; other field types, keys, and layouts need coverage. |
| Physical control | Exact identifier/label press | Partial, scoped verification | Settings navigation observed through fresh AX targets, live state, hit, and portrait display checks. Other apps/overlays/rotations remain incomplete. |
| Physical control | Scroll element into view | Partial, scoped verification | One native action with fresh selector/state/display guards and read-only postcondition checks. Settings movement verified through CLI; real MCP already-visible native-false case passed. Only targets already present in the bounded snapshot can be selected. |
| Physical control | Foreground app selection | Partial, scoped verification | Primary-display centre selection verified for Settings trees and exact identifier/label presses without PID. Overlays, embedded processes, rotations, and other families remain incomplete. |
| Observation | Physical screenshot | Verified | Awake/unlocked iPhone 13 mini USB capture. Earlier black captures preceded confirmed wake/unlock. |
| Observation | Physical accessibility tree | Partial, scoped verification | Explicit-PID and automatically selected Settings trees verified through CLI and real MCP. Snapshot-local IDs; non-atomic; broad coverage unproven. |
| Observation | Physical screenshot + tree workflow | Partial, scoped verification | Physical screen auto/tree integration implemented; real MCP returned Settings hierarchy and inline PNG. Sequential capture/query; physical OCR accuracy remains unverified. |
| Observation | OCR | Partial | Simulator fixture verified; physical accuracy and OCR selector actions remain unverified/missing. |
| Observation | Physical finite recording | Partial, scoped verification | Explicit CoreDevice backend produced two-second H.264/HEVC captures on USB iPhone 13 mini through CLI/MCP. Device-side teardown unconfirmed; sharing indicator persists. Default devicectl recording rejected with capability error 1001. |
| Observation | Live mirroring/streaming | Missing | Internal HID media setup does not constitute a user-facing capture/session feature. |
| Apps | Launch installed apps | Partial, scoped verification | Settings launch verified; other launch restrictions need coverage. |
| Apps | List installed apps | Verified | Selected iPhone 13 mini returned 74 entries, including system components; private inventory stays under ignored tmp/. Other device families remain unverified. |
| Apps | Install/uninstall/terminate/URLs | Implemented, unverified physically | Physical command plans exist; Safari URL preflight failed in one check. No broad physical lifecycle claim. |
| Apps | App-container files | Partial | Raw listing/pull/push exist. Tool-owned temporary-domain copy round trip verified; actual app-container permission/round-trip proof missing. Xcode-format export/replacement missing. |
| Diagnostics | Saved reports | Partial | Physical listing verified; download unverified. Parsing, symbolication, filters, and deletion missing. |
| Diagnostics | Finite OS logs | Implemented, unverified | Duration/entry/byte limits tested synthetically; live capture incomplete. Separate from saved-report parity. |
| Development | Build & Run | Partial, scoped verification | Simulator project/workspace flows verified; physical signing/deployment, scheme discovery, general progress/cancellation incomplete. |
| Agents | Human handoff | Partial | Explicit terminal/MCP form flow and per-device mutation pause tested. Automatic prompt detection, notifications, and mirror banners missing. |
| Agents | Multiple-device coordination/activity/approvals | Partial | Explicit command targets exist. Coordinated sessions, activity tracking, and application approval policy missing. |
| Platforms | iOS simulators | Partial, scoped verification | Core input, AX tree/selectors, screenshots, finite H.264/HEVC recording, and Build & Run flows verified. Simulator pinch/arbitrary moving multitouch missing. |
| Platforms | Apple Watch / watch simulators | Missing | No dedicated product support or live verification. |
| Platforms | iPad-specific coverage | Partial, unverified | Generic command paths exist; dedicated physical iPad, multitasking, and display behavior remain unverified. |
| Platforms | Apple TV / tvOS | Missing | No dedicated control implementation or verification. |
| Platforms | Duo targets | Missing dedicated coverage | No verified posture/display/control support; generic device-ID acceptance is insufficient. |
| Interface | Swift CLI and shared MCP | Partial | Swift CLI and 33 stdio MCP tools share operations. Physical private protocols use an optional Rust bridge; native HID helper uses Objective-C/Swift/assembly. HTTP, general cancellation/progress, and consistent structured CLI errors remain incomplete. |

The old idevice **HID** path returned successful receipts without visible Home/tap effects. Verified physical touch/keyboard operations use the native CoreDevice backend. The separate idevice **AX** path has verified tree reads and selector presses. These results must not be conflated.

Physical controls/actions remain the user's priority. No percentage is assigned: features differ substantially in scope, and implementation counts would hide verification gaps.
