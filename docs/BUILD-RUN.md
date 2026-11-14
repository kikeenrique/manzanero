# Build, install and launch an iOS app

`build-run` uses the selected Xcode to build an explicit project/workspace, choose one application product, install it and launch it on an iPhone/iPad or iOS simulator.

```sh
appledevicescmd simulator <UUID> build-run 'My App.xcodeproj' 'My App'
appledevicescmd physical <UDID> build-run 'My App.xcworkspace' 'My Scheme' --configuration Release
appledevicescmd simulator <UUID> build-run 'My App.xcworkspace' 'My Scheme' --app-target 'Main App'
appledevicescmd --dry-run simulator <UUID> build-run 'My App.xcodeproj' 'My App'
```

## Required inputs

The project/workspace must already exist, and a scheme is required. Configuration defaults to `Debug`; custom names are passed literally. If the scheme builds multiple apps, select one with `--app-target`.

Use an explicit physical hardware UDID or CoreDevice UUID, or a simulator UUID. Names and `booted` are rejected so Xcode's build destination and deployment target agree. Simulators must already be booted. Project generation, automatic scheme selection, folders and non-iOS destinations are unsupported.

xcsift must be on PATH. Physical builds use the project's existing signing configuration and locally available signing assets; the CLI does not enable provisioning updates or developer-portal registration.

## Execution

1. Query JSON build settings for the requested project, scheme, configuration and destination.
2. Resolve exactly one application target, its product path and bundle identifier.
3. Build into a new `tmp/build-run-<UUID>/` directory.
4. Validate the app's Info.plist against its expected bundle ID, application package type and destination platform.
5. Install it, then launch with terminate-existing behavior.

Build directories retain derived data, source-package state and raw `build.log`. Project scripts may write elsewhere according to their own configuration.

Every invocation uses an argument array. The merged Xcode log is passed to xcsift after build completion; diagnostics go to stderr. Xcode's exit status remains authoritative. Devicectl options precede the app operand so they are not forwarded as app arguments.

## Results and failures

Success returns JSON with `status: launched`, bundle identifier, app path, build directory and backend launch result. `verified: false` means app UI/continued health has not been checked. Follow with a screenshot, tree or app-specific assertion.

A failed build or product validation stops before install. Failed install stops before launch. Failed launch can leave an already-installed app. No rollback is promised.

Dry-run returns the planned argument arrays and deployment description without resolving an app, creating the build directory or querying a device.

## Verification and limits

Simulator project/Debug and workspace/Release flows were checked. A standalone Settings launch verified physical option ordering; complete physical signing/build/install/launch remains unverified.

Streaming progress, general cancellation coordination, a build deadline, reuse of earlier build directories, automatic symbolication and crash monitoring are unfinished. MCP `build_run` shares these limits. See [verification](VERIFICATION.md) and the [roadmap](ROADMAP.md).
