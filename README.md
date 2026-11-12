# appledevicescmd

A Swift CLI in development for Apple-device device control, with an optional stdio MCP interface. The CLI uses Xcode tools, Vision, AXe for simulator control, an optional Rust idevice bridge, and an optional native CoreDevice input helper. **Full feature parity is not implemented.**

See the [roadmap and feature sources](docs/ROADMAP.md), [backend setup](docs/DEPENDENCIES.md), [verification records](docs/VERIFICATION.md), [investigation](docs/ANALYSIS.md), and [documentation review findings](docs/DOCUMENTATION-REVIEW.md). Repository workflow rules are in [AGENTS.md](AGENTS.md).

## Build and run

Requires macOS 15 or later, Swift 6.2 or later, and Xcode selected as the active developer directory. Development tasks also require mise and xcsift on PATH.

```sh
mise run build
export PATH="$PWD/.build/debug:$PWD/tmp/bin:$PATH"
appledevicescmd --help
appledevicescmd devices physical
appledevicescmd devices simulators
appledevicescmd doctor
```

After building, `mise run cli <arguments...>` runs the executable with `tmp/bin` on PATH for the optional physical bridge. It does not build or install missing backends automatically.

`devices physical` currently returns the unfiltered CoreDevice JSON inventory, which can include simulators. `devices simulators` returns simctl JSON. `doctor` checks whether Xcode and the two discovery commands succeed; it does not verify device trust, UI Automation, input delivery, or optional-backend installation.

For a physical target, run `appledevicescmd physical <device> readiness` to report Developer Mode, developer-image services, connection/pairing, and preparation steps. Known disabled Developer Mode is also reported before developer-operation dispatch. See [readiness checks and limits](docs/READINESS.md).

Build the optional physical protocol bridge with mise (tested with 2026.10.20):

```sh
mise run idevice:build
# For a cached debug build and bridge tests:
mise run idevice:build --debug --offline
mise run idevice:test --offline
```

These tasks use Rust 1.99.1 and keep its toolchain, Cargo downloads, and generated bridge under `tmp/`. `--offline` applies to Cargo dependencies; the pinned toolchain must already be installed. See [dependency details](docs/DEPENDENCIES.md).

## Optional MCP interface

`appledevicescmd mcp` serves device tools over stdio using the official Swift MCP SDK. It shares the CLI's command service and backends. Configure an MCP host with the executable's absolute path and `args: ["mcp"]`; local paths use the server's working directory. The host controls approvals. Initial pairing remains interactive in the CLI.

See [MCP tools, configuration, and limits](docs/MCP.md). Backend availability and hardware-verification limits apply equally to CLI and MCP calls.

## Device commands

Replace placeholders with your device identifier and paths. App management and screenshot commands use Xcode's tools:

```sh
appledevicescmd physical <device> apps
appledevicescmd physical <device> processes
appledevicescmd physical <device> details
appledevicescmd physical <device> terminate <pid>
appledevicescmd physical <device> open-url 'myapp://profile'
appledevicescmd physical <device> install 'tmp/My App.app'
appledevicescmd physical <device> launch com.example.app
appledevicescmd physical <device> screenshot tmp/screen.png
appledevicescmd simulator booted screenshot tmp/simulator.png
appledevicescmd --dry-run physical <device> uninstall com.example.app
```

Physical `terminate` takes a positive PID (find it with `processes`); simulator `terminate` takes a bundle identifier. Physical `open-url` requires an absolute URL with a scheme.

App-container file operations use the bundle identifier and a relative path (`.` means the root):

```sh
appledevicescmd physical <device> files com.example.app Documents
appledevicescmd physical <device> pull com.example.app Documents/data.json 'tmp/My Data.json'
appledevicescmd physical <device> push com.example.app 'tmp/My Data.json' Documents/data.json
```

Listing is nonrecursive. Absolute remote paths and `..` components are rejected. Uploads do not request removal of unrelated destination contents; files at the selected destination may still be replaced according to devicectl's copy semantics. Container access depends on the device and app's permissions, typically development-installed apps. These raw file operations do not implement Xcode `.xcappdata` package export or whole-container replacement.

These physical commands return devicectl JSON. Simulator app/lifecycle/screenshot commands preserve simctl output, which is not always JSON. Errors go to stderr with a nonzero exit status. The Swift CLI's errors are currently text; the protocol bridge writes JSON errors that the CLI can wrap in text. `--dry-run` prints an executable and argument array without executing the operation. See `--help` for all implemented commands.

Physical command planning and screenshot flags were checked against Xcode 27.2. Details and awake/unlocked screenshot capture are verified on the iPhone 13 mini. Earlier captures were black before the user confirmed wake/unlock; the exact cause was not isolated. Direct devicectl copies round-tripped a synthetic fixture in a tool-owned temporary domain. App-container listing/copies, termination, and URL opening are not yet verified live.

## Human handoff

`appledevicescmd physical <UDID> handoff 'Complete the step on the phone'` waits in an interactive terminal for `done`, `decline`, or `cancel`. MCP `request_handoff` uses a host completion checkbox and pauses that device's mutation calls while waiting. No credentials are collected; acknowledgement is separate from verified device success. See [handoff behavior and limits](docs/HANDOFF.md).

## Screen recording

```sh
appledevicescmd simulator <UUID> record tmp/demo.mp4 5
appledevicescmd physical <device> record tmp/phone.mp4 5
```

Finite recording accepts 1...300 seconds and optional `h264`/`hevc`. It refuses existing destinations and validates the staged video before publishing it. Simulator capture is verified in both codecs; native physical recording remains device-dependent and unverified. MCP exposes the same operation as `record_screen`. See [recording behavior and limits](docs/RECORDING.md).

## Build and run from source

```sh
appledevicescmd simulator <UDID> build-run 'My App.xcodeproj' 'My App'
appledevicescmd physical <UDID> build-run 'My App.xcworkspace' 'My App' --configuration Release
```

Build & Run requires an explicit iOS target, a scheme, and xcsift on PATH. Configuration defaults to Debug; `--app-target` selects one app in a multi-app scheme. It builds, checks the app's metadata, installs it, and restarts it. JSON results go to stdout and build diagnostics to stderr; artifacts/logs stay under `tmp/`. Simulator project and workspace flows are verified; physical signing/deployment is not. See [Build & Run behavior and limits](docs/BUILD-RUN.md).

## Reports and diagnostic logs

List saved reports or download a selected relative path through Xcode:

```sh
appledevicescmd physical <device> reports
appledevicescmd physical <device> reports Retired
appledevicescmd physical <device> report 'My App.ips' 'tmp/My App.ips'
```

These use the `systemCrashLogs` domain and list without recursion. Listing returns devicectl JSON metadata; downloading writes the report to the host destination and returns devicectl JSON. A destination may be overwritten according to Xcode's copy semantics. Listing is verified on a physical phone; downloading is not. Parsing, symbolication, type filters, and deletion are not implemented.

The optional idevice bridge also provides experimental finite OS-log capture, distinct from saved reports:

```sh
appledevicescmd physical <UDID> logs 5
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> logs 5 123
```

Duration is 1...30 seconds after trace startup; the optional PID must be positive. JSON includes `entries`, `stopReason`, and `truncated`. Capture stops at the duration, 2000 entries, or 4 MiB of serialized entry data. The byte cap excludes the result envelope and upstream decoder allocations. Service failures return errors rather than partial success. Setup remains within the bridge's 60-second overall deadline. Live capture and device-side subscription cleanup are unverified; the client closes its connection when capture ends.

## Simulator input and hierarchy

Install [AXe](https://github.com/cameroncooke/AXe) separately and put it on PATH. This repository does not bundle AXe binaries.

```sh
appledevicescmd simulator <UDID> tree
appledevicescmd simulator <UDID> tap-label Settings
appledevicescmd simulator <UDID> tap-id com.example.submit
appledevicescmd simulator <UDID> tap 100 200
appledevicescmd simulator <UDID> swipe 200 600 200 200 0.5
appledevicescmd simulator <UDID> drag 100 200 200 200 0.6
appledevicescmd simulator <UDID> type 'hello'
appledevicescmd simulator <UDID> button home
```

Input and tree commands require an explicit simulator UUID, not `booted`. Coordinates are interface points. Tree output preserves AXe's JSON. Input returns a JSON dispatch receipt with `verified: false`; confirm the app's response with another tree or screenshot. Typing is limited to US keyboard text, tab, and newline. AXe enforces platform-specific input restrictions.

**Live verified:** the CLI read an iPhone simulator's home-screen tree, tapped Settings by label, and read the Settings tree. Other input commands have not been verified live. See [exact coverage](docs/VERIFICATION.md).

## Experimental physical input and accessibility

For the physically verified Home/tap/drag, two-contact map zoom, Unicode paste, and Backspace path, build and explicitly select the [native CoreDevice backend](docs/NATIVE-INPUT.md):

```sh
mise run coredevice:build
mise run cli --physical-backend coredevice physical <device> button home
mise run cli --physical-backend coredevice physical <device> tap 0.5 0.5
mise run cli --physical-backend coredevice physical <device> key backspace
mise run cli --physical-backend coredevice physical <device> paste 'mañana 🚀 中'
```

This optional MIT-licensed helper uses installed Apple private frameworks. The iPhone must be awake/unlocked for the tested UI flow, with Developer Mode and **Settings → Developer → Enable UI Automation** enabled. The idevice backend below remains the default; no input is retried automatically through another backend.

Native `paste` replaces the phone clipboard and pastes once into the already-focused field. It does not focus, select all, submit, restore the clipboard, or approve iOS permission prompts. MCP exposes it as `paste_text`; existing `type_text` retains its previous behavior. See [paste semantics and partial failures](docs/NATIVE-INPUT.md#keyboard-and-unicode-paste).

With the optional `appledevices-idevice` bridge on PATH:

```sh
appledevicescmd physical <UDID> hid-info
appledevicescmd physical <UDID> tap 0.5 0.5
appledevicescmd physical <UDID> multi-tap 0.25 0.5 0.75 0.5
appledevicescmd physical <UDID> pinch 0.5 0.5 0.5 0.8 0.5
appledevicescmd physical <UDID> multi-drag 0.5 0.25 0.5 0.1 0.5 0.75 0.5 0.9 0.5
appledevicescmd physical <UDID> drag 0.5 0.8 0.5 0.2 0.6
appledevicescmd physical <UDID> button home
appledevicescmd physical <UDID> key return
appledevicescmd physical <UDID> type 'Hello from appledevicescmd'
appledevicescmd physical <UDID> ax-snapshot
appledevicescmd physical <UDID> ax-snapshot tmp/accessibility.plist
appledevicescmd decode-ax-archive tmp/accessibility.plist
```

Physical touch coordinates are normalized 0...1, unlike simulator interface points. In the idevice backend, `multi-tap` sends simultaneous contacts and release. `multi-drag` moves two to five contacts together; `pinch` generates a horizontal two-contact pinch/spread. Both moving gestures accept explicit `--physical-backend coredevice` (MCP `backend: coredevice`). Native two-contact spread/inward movement visibly zoomed Maps on the iPhone 13 mini. Three-to-five-contact effects and all idevice gesture effects remain unverified. Every receipt indicates dispatch only. See [multitouch syntax and cleanup limits](docs/MULTITOUCH.md).

Physical `type` is experimental and accepts 1...512 printable US-layout ASCII characters, tab, and LF newline. It uses an owned virtual keyboard, attempts reset/removal after dispatch, and requires the phone's hardware-keyboard layout to match the US mapping. Unicode is unsupported; layout, Caps Lock, and actual entered text remain unverified on hardware. See [physical typing details](docs/PHYSICAL-TYPING.md).

`ax-snapshot` returns an experimental accessibility callback archive with `parsedHierarchy: false`. An optional new `.plist` path saves it privately and returns metadata; `decode-ax-archive` inspects the saved structure offline. USB callback acquisition and correlated cleanup are verified on the iPhone 13 mini. Numeric attribute meanings, a normalized physical UI tree, stable element references, and selector taps remain unfinished. See [protocol evidence and limitations](docs/ACCESSIBILITY-PROTOCOL.md).

The default connection requires the exact UDID through usbmuxd. The earlier phone was absent from usbmuxd; the selected iPhone 13 mini subsequently completed read-only bridge HID discovery over USB after Developer Mode was enabled. This does not verify input delivery. An independent Wi-Fi pairing path is implemented but not verified live:

```sh
mkdir -p tmp/pairings
appledevicescmd pair wifi <host> <port> tmp/pairings/phone.pairing.plist
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> hid-info
```

Initial pairing uses the device's approval/PIN flow. See [Wi-Fi endpoint discovery and setup](docs/DEPENDENCIES.md#wi-fi-pairing). Pairing records contain private keys and must stay out of version control. Idevice input effects, Wi-Fi pairing, and reconnection remain unverified on hardware; USB accessibility callback capture and the explicit native Home/tap/drag path are verified as described above.

## Screen inspection, OCR, and remaining work

`appledevicescmd simulator <UUID> screen auto` captures a PNG and prefers a useful accessibility hierarchy, falling back to Vision OCR. Physical `screen auto` selects OCR because a parsed physical hierarchy is unavailable. If automatic analysis fails, the result explicitly reports `method: image-only` and `status: partial`, retaining the screenshot and diagnostics. Use `screen tree` (simulator only) or `screen ocr` to require that analysis method. MCP exposes the same workflow as `get_screen`. See [screen inspection and coordinate limits](docs/SCREEN-UNDERSTANDING.md).

`appledevicescmd ocr <image-path>` also accepts an existing image. Vision returns text, confidence, and bounds normalized to 0...1 with the origin at the top left. A simulator fixture was recognized successfully; the earlier `Failed to create CVPixelBuffer` failure remains unexplained, and broad recognition accuracy is unverified.

User-facing streaming sessions, verified physical recording and parsed accessibility, Xcode-format container export/replacement, complete saved-report management, settings controls, and automatic human-prompt detection remain outstanding. Native Home/tap/drag, two-contact map zoom, Unicode clipboard paste, and Backspace have physical verification on the selected USB phone; wider multitouch coverage remains incomplete. Explicit handoff and MCP expose the implemented workflow operations. Build & Run has a verified simulator path; physical deployment remains unverified. Raw app-container copies, report downloads, and experimental OS-log capture exist but have not been verified live. The [roadmap](docs/ROADMAP.md) distinguishes documented vendor features, explicit user requirements, and proposed CLI engineering work.
