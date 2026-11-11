# appledevicescmd

A Swift command-line project for Apple device control and agent integration. See [the investigation](docs/ANALYSIS.md) and [implementation roadmap](docs/ROADMAP.md). Repository workflow rules are in [AGENTS.md](AGENTS.md).

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
