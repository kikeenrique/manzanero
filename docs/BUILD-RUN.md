# Build and run an iOS app

`build-run` builds a selected Xcode project or workspace, installs the resulting application, and launches it on an explicit iPhone/iPad or iOS simulator target. The CLI orchestration is Swift; compilation and deployment use the selected Xcode's `xcodebuild`, `devicectl`, and `simctl`.

```sh
appledevicescmd simulator <UDID> build-run 'My App.xcodeproj' 'My App'
appledevicescmd physical <UDID> build-run 'My App.xcworkspace' 'My App' --configuration Release
appledevicescmd simulator <UDID> build-run 'My App.xcworkspace' 'My Scheme' --app-target 'Main App'
appledevicescmd --dry-run simulator <UDID> build-run 'My App.xcodeproj' 'My App'
```

Configuration defaults to `Debug`; custom configuration names are passed literally. A scheme is required. If it builds multiple application targets, select one with `--app-target`. The project/workspace must already exist; folders, automatic scheme selection, project generation, and non-iOS destinations are not supported. Simulators must already be booted. Device names and `booted` are rejected to keep Xcode's build destination and deployment target the same explicit identifier.

## Execution and output

1. Query build settings as JSON for the project, scheme, configuration, and destination.
2. Select exactly one application target for `iphoneos` or `iphonesimulator` and resolve its product path and bundle identifier.
3. Build into a unique `tmp/build-run-<UUID>/` directory. Derived data, cloned source packages, package cache, and the raw `build.log` are kept there. Project-defined scripts/settings may write to their own configured locations.
4. Check the built app's Info.plist for the expected bundle identifier, application package type, and destination platform.
5. Install the selected app, then launch it with the backend's terminate-existing option so an old process does not continue running.

Every external invocation uses an argument array. The merged Xcode build log is passed to xcsift as file-backed stdin after the build finishes. Formatted diagnostics go to stderr. The Xcode process's exit status remains authoritative even when formatting succeeds. Failed builds and mismatched products stop before installation; failed installs stop before launch. A launch failure returns nonzero, but an already completed installation remains on the device.

On success, stdout contains one JSON document with `status: launched`, bundle identifier, app path, build directory, and the backend's launch result. `verified: false` means the CLI has not checked app UI or continued health. Follow with `tree`, a screenshot, or app-specific checks. Dry-run prints build/settings argument arrays and describes subsequent deployment; it does not resolve an app, create the build directory, or run Xcode.

## Signing and limitations

Physical builds use the project's existing signing configuration and locally available signing assets. The CLI does not enable provisioning updates or developer-portal device registration. Xcode signing failures are returned to the caller. Physical Build & Run remains unverified on hardware.

The command does not yet provide streaming build progress, cancellation coordination, a build deadline, incremental reuse of a previous build directory, automatic symbolication, or crash monitoring. Its shared operation is also exposed as the MCP `build_run` tool; that does not add those missing behaviors. An interrupted command may leave build artifacts or a deployed app; no rollback is promised. Do not infer full vendor Build & Run parity from the verified simulator path.

See [verification records](VERIFICATION.md) for the exact live checks and [roadmap](ROADMAP.md) for remaining features.
