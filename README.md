# appledevicescmd

A Swift CLI in development for Apple-device device control. The CLI uses Xcode tools, Vision, an optional AXe simulator backend, and an optional Rust bridge to the open-source idevice library. **Full feature parity is not implemented.**

See the [roadmap and feature sources](docs/ROADMAP.md), [backend setup](docs/DEPENDENCIES.md), [verification records](docs/VERIFICATION.md), and [investigation](docs/ANALYSIS.md). Repository workflow rules are in [AGENTS.md](AGENTS.md).

## Build and run

Requires macOS 15 or later, Swift 6.2 or later, and Xcode selected as the active developer directory.

```sh
swift build
export PATH="$PWD/.build/debug:$PWD/tmp/bin:$PATH"
appledevicescmd --help
appledevicescmd devices physical
appledevicescmd devices simulators
appledevicescmd doctor
```

`devices physical` currently returns the unfiltered CoreDevice JSON inventory, which can include simulators. `devices simulators` returns simctl JSON. `doctor` checks whether Xcode and the two discovery commands succeed; it does not verify device trust, UI Automation, input delivery, or optional-backend installation.

Build the optional physical protocol bridge with mise (tested with 2026.10.20):

```sh
mise run idevice:build
# For a cached debug build and bridge tests:
mise run idevice:build --debug --offline
mise run idevice:test --offline
```

These tasks use Rust 1.99.1 and keep its toolchain, Cargo downloads, and generated bridge under `tmp/`. `--offline` applies to Cargo dependencies; the pinned toolchain must already be installed. See [dependency details](docs/DEPENDENCIES.md).

## Device commands

Replace placeholders with your device identifier and paths. App management and screenshot commands use Xcode's tools:

```sh
appledevicescmd physical <device> apps
appledevicescmd physical <device> install 'tmp/My App.app'
appledevicescmd physical <device> launch com.example.app
appledevicescmd physical <device> screenshot tmp/screen.png
appledevicescmd simulator booted screenshot tmp/simulator.png
appledevicescmd --dry-run physical <device> uninstall com.example.app
```

These physical commands return devicectl JSON. Simulator app/lifecycle/screenshot commands preserve simctl output, which is not always JSON. Errors go to stderr with a nonzero exit status. The Swift CLI's errors are currently text; the protocol bridge writes JSON errors that the CLI can wrap in text. `--dry-run` prints an executable and argument array without executing the operation. See `--help` for all implemented commands.

Physical command planning and screenshot flags were checked against Xcode 27.2. Those checks do not establish live physical app management or capture behavior.

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

With the optional `appledevices-idevice` bridge on PATH:

```sh
appledevicescmd physical <UDID> hid-info
appledevicescmd physical <UDID> tap 0.5 0.5
appledevicescmd physical <UDID> multi-tap 0.25 0.5 0.75 0.5
appledevicescmd physical <UDID> drag 0.5 0.8 0.5 0.2 0.6
appledevicescmd physical <UDID> button home
appledevicescmd physical <UDID> key return
appledevicescmd physical <UDID> ax-snapshot
```

Physical touch coordinates are normalized 0...1, unlike simulator interface points. `multi-tap` sends simultaneous contacts and release; moving multitouch gestures are not implemented. Input receipts indicate dispatch only.

`ax-snapshot` is an experimental protocol probe that returns a base64 accessibility callback archive with `parsedHierarchy: false`. It does not provide a parsed physical UI tree, stable element references, or selector taps. See [protocol evidence and limitations](docs/ACCESSIBILITY-PROTOCOL.md).

The default connection requires the exact UDID through usbmuxd. The phone used for investigation was visible in CoreDevice but absent from usbmuxd; live HID discovery failed before input. An independent Wi-Fi pairing path is implemented but not verified live:

```sh
mkdir -p tmp/pairings
appledevicescmd pair wifi <host> <port> tmp/pairings/phone.pairing.plist
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> hid-info
```

Initial pairing uses the device's approval/PIN flow. See [Wi-Fi endpoint discovery and setup](docs/DEPENDENCIES.md#wi-fi-pairing). Pairing records contain private keys and must stay out of version control. Physical input, accessibility snapshots, pairing, and reconnection remain unverified on hardware.

## OCR and remaining work

`appledevicescmd ocr <image-path>` uses macOS Vision and returns JSON text, confidence, and bounds normalized to 0...1 with the origin at the top left. It is a standalone image command; automatic screenshot/OCR fallback is not implemented. The initial runtime fixture check failed with `Failed to create CVPixelBuffer`; the cause and recognition accuracy remain unverified.

Recording, user-facing streaming sessions, physical text entry and parsed accessibility, file/container transfers, reports/logs, settings controls, Build & Run, handoff, and MCP remain outstanding. The [roadmap](docs/ROADMAP.md) distinguishes documented vendor features, explicit user requirements, and proposed CLI engineering work.
