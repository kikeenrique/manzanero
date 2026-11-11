# appledevicescmd

A Swift command-line project for Apple device control and agent integration. See [the investigation](docs/ANALYSIS.md) and [implementation roadmap](docs/ROADMAP.md). See [backend dependencies and build instructions](docs/DEPENDENCIES.md) and [verification records](docs/VERIFICATION.md). Repository workflow rules are in [AGENTS.md](AGENTS.md).

Requires Swift 6.2 or later and Xcode. Current commands:

```sh
swift build
.build/debug/appledevicescmd --help
.build/debug/appledevicescmd devices physical
.build/debug/appledevicescmd devices simulators
.build/debug/appledevicescmd doctor
.build/debug/appledevicescmd ocr tmp/screen.png
```

Discovery returns Apple's JSON payload. Failures go to stderr with nonzero exit status. `doctor` returns a JSON array of checks and exits nonzero if a service is unavailable. Device control and MCP are under development.

App management and capture commands accept an explicit device identifier:

```sh
appledevicescmd physical <device> apps
appledevicescmd physical <device> install 'tmp/My App.app'
appledevicescmd physical <device> launch com.example.app
appledevicescmd physical <device> screenshot tmp/screen.png
appledevicescmd simulator booted screenshot tmp/simulator.png
appledevicescmd --dry-run physical <device> uninstall com.example.app
```

See `--help` for simulator boot/shutdown, app termination, and URL opening. Physical-device commands return devicectl JSON; simulator commands preserve simctl's output format. These operations depend on the selected Xcode version; screenshot support was checked against Xcode 27.2's devicectl help. Commands have been built and their generated argument lists checked, but live device execution remains unverified in this environment. The CLI does not overwrite safeguards imposed by the device or Apple tools.

`ocr <image-path>` uses Apple's Swift Vision `RecognizeTextRequest` (macOS 15+) and returns JSON containing text, confidence and bounding rectangles. Coordinates are normalized to 0–1 with the origin at the top left of the image. OCR finds visible text; it does not supply accessibility roles or off-screen elements. The command builds successfully, but the first runtime fixture check failed inside Vision with `Failed to create CVPixelBuffer` in this restricted session. Recognition accuracy and execution outside the session still need verification. A generated fixture is available at `tmp/ocr-fixture.png` for a Terminal check.


Simulator input and accessibility use the optional [AXe](https://github.com/cameroncooke/AXe) backend (MIT, by Cameron Cooke; uses Meta IDB). Install AXe separately and put it on PATH; its binaries are not bundled here. AXe uses Xcode simulator interfaces and does not provide physical-device input.

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

These operations require an explicit simulator UUID, not `booted`. Tree output preserves AXe's JSON hierarchy, including identifiers, labels, roles, and frames. Coordinates are interface points. Input returns `{"backend":"axe","status":"dispatched","verified":false}`; backend messages go to stderr. Confirm app behavior with a subsequent tree or screenshot. AXe typing supports US keyboard text, tab, and newline. Platform-specific input restrictions are enforced by AXe.

See [verification records](docs/VERIFICATION.md) for the tested environment and exact coverage. Physical input now has an optional idevice bridge; live physical behavior, moving multitouch gestures, streaming capture, and MCP remain outstanding.


Physical HID is experimental and uses a source-built `idevice` dependency pinned by revision and lockfile. See [build instructions and connection limits](docs/DEPENDENCIES.md). With `appledevices-idevice` on PATH:

```sh
appledevicescmd physical <UDID> hid-info
appledevicescmd physical <UDID> tap 0.5 0.5
appledevicescmd physical <UDID> multi-tap 0.25 0.5 0.75 0.5
appledevicescmd physical <UDID> drag 0.5 0.8 0.5 0.2 0.6
appledevicescmd physical <UDID> button home
appledevicescmd physical <UDID> key return
```

Physical touch coordinates are normalized 0...1; simulator coordinates are interface points. The default bridge connection requires the target UDID through usbmuxd. An explicit Wi-Fi pairing and independent tunnel path is also implemented; see [Wi-Fi setup](docs/DEPENDENCIES.md#wi-fi-pairing). CoreDevice-only discovery alone does not provide a tool-specific pairing record. These physical input operations have passed build and parser tests but have **not** passed live-device verification. The attempted HID discovery returned device-not-found through usbmuxd. Successful input receipts indicate dispatch, not a verified app outcome.


For a separately paired Wi-Fi connection:

```sh
appledevicescmd pair wifi <host> <port> tmp/pairings/phone.pairing.plist
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> hid-info
```

Create the destination directory first. Initial pairing prompts for device approval/PIN and returns the UDID. Pairing records are private and excluded from Git. Wi-Fi setup and physical input are implemented but **not live-verified**. [Transport investigation](docs/TRANSPORT.md) records the unsuccessful attempts to reuse Apple's connection and the reason for the independent tunnel.
