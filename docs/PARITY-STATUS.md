# Feature parity status

Checkpoint: `d69a44b`, 2026-11-12. Full device-control tooling parity is not complete. This classifies the repository's [recorded parity inventory](ROADMAP.md), rather than claiming a newly audited vendor feature list. Verification is scoped to the device, screen, transport, and environment recorded in [VERIFICATION.md](VERIFICATION.md).

Scope clarification: all Apple device families are in scope, explicitly including iPhone, iPad, Apple Watch, Apple TV, and Duo targets. Android is excluded and is not an unfinished requirement. The same physical iPhone result cannot verify another device family.

**Verified** means a scoped live result was observed. **Implemented, unverified** means code exists without sufficient live proof. **Partial** means important functionality or coverage remains missing. **Missing** means there is no product implementation. **In progress** means current work has not reached a verified, committed checkpoint. Passing tests alone does not establish hardware behavior.

| Category | Feature | Status | Evidence or remaining gap |
| --- | --- | --- | --- |
| Devices | iPhone USB discovery/readiness | Partial, scoped verification | CoreDevice details and Developer Mode/image checks work; physical inventory can include simulators. |
| Devices | Wi-Fi pairing/reconnection | Implemented, unverified | Independent pairing/tunnel path exists; hardware pairing/reconnection/input proof remains missing. |
| Physical control | Home, tap, drag | Verified | Native CoreDevice backend on iPhone 13 mini over USB. Other buttons/orientations remain unverified. |
| Physical control | Pinch and moving multitouch | Partial, scoped verification | Native two-contact Maps zoom in/out verified. Three-to-five-contact effects and failure cleanup on hardware remain unverified; arbitrary timed paths are missing. |
| Physical control | Unicode paste / Backspace | Verified | Settings search insertion/removal observed. Paste explicitly replaces the phone clipboard; other field types, keys, and layouts need coverage. |
| Physical control | Exact identifier/label press | Partial, scoped verification | Settings navigation observed through fresh AX targets, live state, hit, and portrait display checks. Other apps/overlays/rotations remain incomplete. |
| Physical control | Foreground app selection | In progress | Uncommitted automatic selection for trees and presses; explicit-PID operations are the committed checkpoint. |
| Observation | Physical screenshot | Verified | Awake/unlocked iPhone 13 mini USB capture. Earlier black captures preceded confirmed wake/unlock. |
| Observation | Physical accessibility tree | Partial, scoped verification | Explicit-PID Settings/search/keyboard tree verified through CLI and real MCP. Snapshot-local IDs; non-atomic; broad coverage unproven. |
| Observation | Physical screenshot + tree workflow | In progress | Uncommitted integration. Committed physical screen auto uses OCR. |
| Observation | OCR | Partial | Simulator fixture verified; physical accuracy and OCR selector actions remain unverified/missing. |
| Observation | Physical finite recording | Implemented, unverified | Command exists; iPhone 13 mini has not completed a capture test. An earlier different phone rejected native recording. |
| Observation | Live mirroring/streaming | Missing | Internal HID media setup does not constitute a user-facing capture/session feature. |
| Apps | Launch installed apps | Partial, scoped verification | Settings launch verified; other launch restrictions need coverage. |
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
| Interface | Swift CLI and shared MCP | Partial | Swift CLI and 30 stdio MCP tools share operations. Physical private protocols use an optional Rust bridge; native HID helper uses Objective-C/Swift/assembly. HTTP, general cancellation/progress, and consistent structured CLI errors remain incomplete. |

The old idevice **HID** path returned successful receipts without visible Home/tap effects. Verified physical touch/keyboard operations use the native CoreDevice backend. The separate idevice **AX** path has verified tree reads and selector presses. These results must not be conflated.

Physical controls/actions remain the user's priority. No percentage is assigned: features differ substantially in scope, and implementation counts would hide verification gaps.
