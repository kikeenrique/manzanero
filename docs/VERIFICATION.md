# Verification records

These are historical, task-specific observations. Earlier counts and limitations describe that revision; they are not the current feature inventory. See [ROADMAP.md](ROADMAP.md) for current status. Unless a live check is explicitly listed, build, parser, and synthetic protocol tests do not establish device behavior.

## 2026-11-11 — simulator interaction backend

Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2, AXe 1.9.0-prerelease.1, iPhone 17 simulator running iOS 27.2.

- `swift test` through xcsift passed with zero errors/warnings: six test functions, including seven invalid-input cases. Coverage includes literal shell-sensitive text and leading-dash selectors, invalid numeric values and ambiguous targets, large subprocess output, and nonzero child-process diagnostics.
- Live CLI `simulator <UDID> tree` returned a JSON SpringBoard accessibility hierarchy.
- Live CLI `simulator <UDID> tap-label Settings` returned a dispatch receipt. A subsequent CLI tree returned an Application labeled Settings, its Settings heading, and settings rows. This verifies the selector tap changed the foreground app.
- Coordinate tap, drag, swipe, typing, and buttons are implemented but their live behavior has not yet been verified. Input success means dispatch only.
- Compiler cache and CoreSimulator services required execution outside the workspace sandbox. This is an environment constraint, not proof of unsupported device services.
- Physical-device input/accessibility, multitouch, streaming, and MCP are not implemented by this backend.

Installed `axe <command> --help` was checked for every wrapped command. Installed `devicectl help` confirms stdout JSON support via `--json-output -`. AXe attribution and installation link are in the root README; no third-party binaries or source are redistributed by this change.


## 2026-11-11 — pinned idevice dependency and physical HID bridge

Environment remains macOS 27.2.1, Xcode 27.2, Apple Swift 6.4.2; bridge built with Rust 1.99.1 (58cf8f9c3). Upstream idevice revision: `89702099f4d7552f704f93b4526756abda319ceb`, version 0.1.68.

- Swift tests through xcsift passed: nine test functions with zero warnings/errors, including ten additional invalid physical-input cases. New checks cover normalized endpoint/midpoint conversion, seconds-to-milliseconds conversion, simultaneous-contact counts, nonfinite/out-of-range coordinates, unsupported buttons/keys, and argument arity.
- Rust bridge build and two unit tests passed. Rust parser tests reject malformed coordinates, durations, multitouch pairs, and keys before connecting to any device. The committed Cargo lockfile was used for the offline repeat build.
- The former Python build helper (since replaced by mise tasks) successfully built the optional helper into `tmp/bin` using the declared Git dependency. The development clone is not used by this build.
- A live read-only `hid-info` check targeted the physical iPhone discoverable through CoreDevice. It returned JSON error `Device not available through usbmuxd: device not found` with exit code 1 and no success payload. No touch, keyboard, or button input was sent. This provides failure-path evidence, not live HID functionality.
- At that revision, connection support was an in-process CoreDeviceProxy tunnel from usbmuxd. Apple's separately paired CoreDevice-only Wi-Fi path was missing; the later explicit pairing path uses a separate tool record, not Apple's existing identity.
- Audio/video stream negotiation, stream ownership detection, input dispatch, and cleanup are compiled but have not been verified on a physical device. The metadata and feature-mask values come from the pinned library's upstream example. The bridge checks for a reported active `streamConfig` before starting; simultaneous-controller behavior and cancellation cleanup remain unverified.


## 2026-11-11 — explicit Wi-Fi pairing and transport

Environment unchanged; Rust 1.99.1 and Swift 6.4.2.

- Swift tests through xcsift passed: 12 test functions, zero warnings/errors. Added checks cover interactive pairing planning, literal paths with spaces, private-record suffix, invalid host/port input, and restriction of `--pairing-file` to the physical HID backend.
- Six Rust tests passed with the pinned library and updated lockfile. Added checks cover pairing-record round trips, wrong-device rejection, malformed records/endpoints, removal when an uncommitted reservation is dropped, mode 0600, and refusal to overwrite an existing record. These test locally generated fixture keys only.
- A dry run of `--pairing-file <path with spaces> physical <UDID> hid-info` produced the expected helper argument array.
- Native `remotectl netcat` proxy and direct-HID probes failed before input. That experimental path was removed; see [TRANSPORT.md](TRANSPORT.md).
- The implemented Wi-Fi path compiles against idevice's remote-pairing and native TLS-PSK APIs and holds its pairing control connection for the tunnel lifetime. No live pairing, trust change, or physical input was attempted. Device-side approval and a PIN are required before that verification can proceed.
- `dns-sd -h` was checked for the documented Bonjour browse/resolve commands. Endpoint discovery is manual and saved endpoint changes are not automatically handled yet.


## 2026-11-11 — experimental accessibility snapshot and mise migration

- Swift tests through xcsift passed: 13 test functions, zero warnings/errors. The additional routing check covers `ax-snapshot`; it sends no device request.
- `mise tasks validate`, `mise run idevice:build --debug --offline`, `mise run idevice:build --offline` (release), and `mise run idevice:test --offline` passed. The Python build helper was removed. Both build modes copy their binary to `tmp/bin`.
- Ten Rust tests passed. Four accessibility tests use synthetic data and an in-memory duplex stream. They cover bad/oversized DTX headers, inconsistent payload lengths, fragment reassembly/order, callback filtering, acknowledgement correlation, and the disable reply. They do not contain captured device payloads.
- No live `ax-snapshot` was attempted. The service selectors and initial Boolean request were inferred from static inspection. A callback archive is not yet a parsed physical UI tree.
- Record-drop tests do not establish cleanup after SIGINT/SIGKILL or a host crash. Documentation now distinguishes those cases.


## 2026-11-11 — Xcode app-data and process commands

Environment remains macOS 27.2.1 / Xcode 27.2, Swift 6.4.2; target phone on iOS 27.2.1.

- Installed help was checked for `device info files`, `device copy from`, `device copy to`, `device process terminate`, and `device process openURL`. The copy interface scopes operations by domain type and identifier; termination takes a PID, not a bundle ID.
- `mise tasks validate` passed for all five tasks. `mise run test` passed 17 Swift test functions with zero warnings/errors. New tests cover upload direction/container scoping, literal paths with spaces and shell-sensitive characters, traversal rejection, operand counts, invalid PIDs/process groups, and missing URL schemes. These are planner tests, not device-delivery tests.
- `mise run build` succeeded. The new Swift build/test tasks run through xcsift with pipefail and project-local caches.
- Live CLI `physical <UDID> details` returned valid JSON with `info.outcome: success` and command type `devicectl.device.info.details`.
- Direct devicectl `copy to` and `copy from` on the physical phone's `temporary` domain, identifier `appledevicescmd-verification`, both returned success. The downloaded synthetic text fixture matched all 91 source bytes, including Unicode and shell-sensitive literal text. Outputs and fixtures are under ignored `tmp/app-data-verification/`; no personal app data was accessed. The synthetic fixture remains in that device temporary domain.
- That round trip verifies Xcode's file-copy mechanism, **not** the CLI's `appDataContainer` permissions or live routing. App-container list/pull/push, physical termination, and physical URL opening are implemented but not live-verified. No app was terminated, no URL was opened, and no app-container data was modified by these checks.
- Raw copies do not establish Xcode `.xcappdata` export/replacement support.

## 2026-11-11 — saved reports and finite OS-log capture

Environment: macOS 27.2.1 / Xcode 27.2, Swift 6.4.2, Rust 1.99.1; target phone on iOS 27.2.1.

- Rechecked installed `devicectl device info files --help` and `device copy from --help`: `systemCrashLogs` is a supported domain. The CLI uses nonrecursive listing and explicit copy direction, without an app domain identifier.
- `mise run test` passed 21 Swift test functions with zero warnings/errors. Report tests cover the complete listing invocation, selected remote/local paths, domain, traversal/operand rejection, and bridge routing with optional pairing and PID. `mise run build` succeeded through xcsift.
- `mise run idevice:test` passed all 14 Rust tests; `mise run idevice:build --debug --offline` succeeded. Four new synthetic collector tests cover idle deadlines, ordered entry limits, serialized-byte limits, and service failures. Existing parser tests additionally reject invalid log durations/PIDs. The lockfile gained chrono for idevice's enabled OS trace feature; the pinned idevice revision is unchanged.
- Live CLI `physical <UDID> reports` returned valid JSON with `info.outcome: success` and 51 top-level entries. Output stays in ignored `tmp/report-listing.json`. No report contents were downloaded, no report was deleted, and no device identifiers or report filenames are committed.
- `report` download remains unverified on hardware. The earlier synthetic temporary-domain copy round trip is not a saved-report download test. Parsing, symbolication, report type filters, and deletion remain unimplemented.
- `logs` is an additional experimental OS trace capture, not evidence of saved-report parity. It uses the pinned library's RSD service/client and parser. Duration begins after trace startup; connection/setup/capture share the bridge's 60-second outer deadline. Captures are capped at 2000 entries/4 MiB of serialized entry data; this is not a memory cap on the upstream wire decoder. A timeout ends the client's connection; device-side cleanup and live trace contents remain unverified. No live log capture was attempted.

## 2026-11-11 — Build & Run orchestration

Environment: macOS 27.2.1 / Xcode 27.2 (27B52), Swift 6.4.2, AXe 1.9.0-prerelease.1; dedicated iPhone 17 simulator on iOS 27.2. The temporary fixture was generated with XcodeGen 2.46.0 under `tmp/build-run-fixture/`; XcodeGen is not a runtime dependency of the CLI.

- Installed `xcodebuild -help` was checked for project/workspace, scheme, configuration, destination, build-settings JSON, derived-data and package-cache flags. Installed `simctl launch` and `devicectl device process launch` help establish the separate terminate-existing flags. No provisioning-update or device-registration flag is enabled.
- `mise run test` passed all 30 Swift test functions with zero warnings/errors. New tests cover literal paths/schemes, explicit destination validation, product ambiguity/platform checks, build → metadata validation → install → launch ordering, restart flags, and stopping after failed builds, mismatched metadata, or failed installs. A real subprocess fixture exits 7 while printing a build-success marker; xcsift succeeds, but the runner still reports build failure and preserves both stdout/stderr in its raw log.
- `mise run build` succeeded through xcsift before live checks; subsequent tests rebuilt the final source. No Rust source or dependency changed in this task.
- Live CLI project/Debug `build-run` built the local SwiftUI fixture, installed it, and returned `status: launched` with a simulator PID. A separate CLI AXe tree identified the fixture and its expected text/accessibility identifier.
- After changing the fixture's visible text, live CLI workspace/Release `build-run` with `--app-target` built and restarted it while the earlier app was open. Its product path was `Release-iphonesimulator`, its launch PID differed, and a subsequent tree contained `appledevicescmd workspace rebuild verified`. This verifies the rebuilt app replaced the visible old content.
- Both real fixture builds passed through xcsift with zero compiler errors/warnings. Xcode emitted a separate destination-resolution diagnostic during its settings query, but returned valid matching build settings and successfully built/deployed both configurations. Raw logs, result JSON, fixture sources, and tree output remain under ignored `tmp/`. The fixture remains installed on the dedicated simulator.
- A physical/Release dry run used the expected `platform=iOS,id=…` destination and argument arrays. Physical execution is covered only by synthetic routing tests, not live signing, installation, or restart. Workspace builds with real external package dependencies, custom configurations, and multi-app schemes are not live-verified.
- This is an iOS Build & Run implementation with explicit scheme selection. Automatic scheme discovery, live progress, coordinated cancellation/deadlines, crash monitoring/symbolication, and source-to-crash integration remain absent. A launch acknowledgement is not a UI-health guarantee; result receipts retain `verified: false`.

## 2026-11-11 — optional Swift MCP interface

Environment: macOS 27.2.1 / Xcode 27.2, Swift 6.4.2, AXe 1.9.0-prerelease.1; dedicated iPhone 17 simulator on iOS 27.2. MCP SDK release 0.12.1 at `a0ae212ebf6eab5f754c3129608bc5557637e605`.

- Inspected a pinned SDK clone in `tmp/mcp-swift-sdk` and the official 2025-11-25 [stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [tool](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) specifications. SwiftPM declares the Git dependency at exact version 0.12.1; its locked revision matches the inspected clone. The SDK supports versions through 2025-11-25; no support for newer wire revisions is claimed.
- CLI and MCP now invoke one Swift `CommandService`; planners and backends remain shared. Interactive pairing is rejected in the service's server mode, before launching a subprocess. Existing pairing files can be selected by path for physical bridge operations.
- `mise run test` passed 38 Swift test functions with zero warnings/errors; the simulator-dependent stdio test is skipped unless explicitly enabled. Tests cover schema/unknown-tool rejection before execution, literal text and pairing routing, structured unsuccessful doctor output, backend errors as tool errors, the shared dry-run path, and interactive-pairing rejection. An SDK client/server exchange over in-memory transport verified initialization, discovery, and domain errors without sending a device request.
- `mise tasks validate` passed all six tasks. `mise run test:mcp-live <UUID>` builds the executable through xcsift and launches its actual `mcp` subprocess. The corrected run passed its integration test in about two seconds, with zero warnings/errors. It verified protocol version 2025-11-25, exact tool-list names/order, a rejected out-of-range physical tap (no device dispatch), live simulator inventory and tree calls, PNG capture with inline `image/png` content, and clean process exit after stdin EOF. This establishes stdio transport and those simulator tools, not every advertised operation.
- The initial stdio harness stalled on Foundation's `read(upToCount:)`, which waited to fill the requested pipe buffer. A one-second stack sample identified that blocked read in the test helper. The owned test/helper processes were stopped; replacing the harness read with a single POSIX read after `poll` resolved it. The initial interrupted run is a failure, not counted as successful verification. The SDK server was not changed to address that harness issue.
- Live screenshots and stderr logs remain under ignored `tmp/mcp-live-*/`; stack-sampling output stays under `tmp/`. No device identifiers, captured screen data, or pairing material are committed. No physical input, pairing, install, uninstall, or app-data mutation was sent by these MCP checks.
- The SDK license/transition notice is preserved in `ThirdParty/`; `Package.resolved` pins the dependency graph. No Rust dependency changed. Existing simulator typing dry-run arguments were checked after extracting the shared service.
- Host-specific MCP registration, HTTP/authentication, later protocol revisions, progress, cancellation coordination, resources/prompts, built-in approvals, and human handoff remain unimplemented or unverified. Physical-backend gaps are unchanged. Successful tool discovery does not establish complete device-control tooling parity.

## 2026-11-11 — finite screen recording

Environment: macOS 27.2.1 / Xcode 27.2, Swift 6.4.2; dedicated iPhone 17 simulator on iOS 27.2.

- Installed `devicectl device capture screen-record --help` confirms native duration, H.264/HEVC, MP4 destination, and timeout options. Installed simctl IO help documents its first-frame stderr marker and SIGINT finalization. AVFoundation's asynchronous asset-loading and image-generation APIs are used to validate a movie before publishing it.
- `mise run test` passed 47 Swift test functions with zero warnings/errors. Added tests cover duration/codec/target/path planning, no forced overwrite, existing-destination preservation before launching a recorder, invalid media rejection, split first-frame marker handling, duration measured after startup, SIGINT finalization, startup timeout, ignored-interrupt cleanup, and early-exit diagnostics. Subprocess tests use local signal-handling fixtures, not a device.
- Live CLI H.264 simulator capture requested two seconds and produced a 2.0167-second movie with a decoded 1206×2622 frame. A separate one-second HEVC capture also finalized and passed the same AVFoundation inspection. Movies and metadata remain under ignored `tmp/recording-verification/`.
- The extended `mise run test:mcp-live <UUID>` passed its stdio integration check in about five seconds. In addition to earlier checks, it invoked `record_screen`, saved a one-second H.264 movie, and verified recorded status and decoded-artifact metadata. The server now exposes 22 tools. This does not establish native physical capture or streaming sessions.
- A native physical recording attempt on the previously selected phone failed with CoreDevice error 1001: `com.apple.coredevice.feature.screenrecording` unsupported. No successful receipt or final movie was published. The user then specified the iPhone 13 mini as the physical test target; the earlier phone's result must not be generalized to it.
- A read-only details query on the specified iPhone 13 mini reported USB/wired connectivity, iOS 27.2, Developer Mode disabled, and developer-image services unavailable. No recording was attempted on it while in that state. Hardware preparation/reporting is a separate follow-up task; its identity and raw details stay under ignored `tmp/`.
- Physical recording, audio, additional-display selection, continuous mirroring, background session controls, and private-protocol recording fallback remain unverified or absent. Decoding one frame does not verify every frame or precise duration. Abrupt parent termination can bypass child cleanup.

## 2026-11-11 — Developer Mode readiness reporting

The user selected the iPhone 13 mini as the physical test target. No further physical checks in this task targeted the earlier phone. Raw inventory/details and the private target selection remain under ignored `tmp/`; no identifiers or serial numbers are committed.

- A fresh read-only details query on the selected phone reported iOS 27.2, a wired connection, paired/connected state, Developer Mode disabled, and developer disk image services unavailable. Xcode returned success with partial information and a Developer Mode warning, demonstrating that command success alone is not readiness.
- `physical <device> readiness` normalized that state into JSON with `status: blocked`, `developerMode: disabled`, `developerDiskImageServices: unavailable`, and enable/restart/confirmation steps. It exited 1 while preserving the structured report. After adding Xcode's documented `--quiet` option, the live check still returned those fields without the verbose hardware dump.
- A live CLI recording request on that phone returned the specific disabled-Developer-Mode instruction before the recorder was dispatched. Developer Mode was not enabled, the phone was not restarted, and no video was captured or published by this check. This result is a preparation blocker, not proof that recording is permanently unsupported on this model.
- `mise run test` passed 54 Swift test functions with zero warnings/errors. New tests cover current enum-shaped state, legacy fallback, precedence over stale deprecated values, unknown/missing/ambiguous metadata, unsuccessful details results, action guidance and exit status, preflight stopping recording/build, and MCP preservation of blocked-state JSON. Fixtures are synthetic and contain no captured hardware data.
- The updated `mise run test:mcp-live <UUID>` passed the full simulator stdio flow with zero warnings/errors, including the now-23-tool catalog and recording. This checks regressions in shared dispatch; it does not test physical MCP input.
- Preflight stops known disabled-mode developer operations. Unknown/unavailable metadata is reported, with backend enforcement retained so an independent idevice pairing is not made dependent on CoreDevice's identity. Developer-image preparation may occur through Xcode; UI Automation, lock state, usbmuxd availability, and live input effects remain outside this check.
