# Build, install and launch an iOS app

`build-run` uses the selected Xcode to build an explicit project/workspace, choose one application product, install it and launch it on an iPhone/iPad or iOS simulator.

```sh
manzanero build-run 'My App.xcodeproj' 'My App' --simulator <UUID>
manzanero build-run 'My App.xcworkspace' 'My Scheme' --configuration Release --device <UDID>
manzanero build-run 'My App.xcworkspace' 'My Scheme' --app-target 'Main App' --simulator <UUID>
manzanero build-run 'My App.xcodeproj' 'My App' --allow-provisioning-updates --allow-device-registration --device <UDID>
manzanero build-run 'My App.xcodeproj' 'My App' --simulator <UUID> --dry-run
```

## Required inputs

The project/workspace must already exist, and a scheme is required. Configuration defaults to `Debug`; custom names are passed literally. If the scheme builds multiple apps, select one with `--app-target`.

Use an explicit physical hardware UDID or CoreDevice UUID, or a simulator UUID. Names and `booted` are rejected so Xcode's build destination and deployment target agree. Simulators must already be booted. Project generation, automatic scheme selection, folders and non-iOS destinations are unsupported.

xcodebuild's `-destination id=` takes the identifier "as shown in the Devices window" (`man xcodebuild`), which for a physical device is the hardware UDID. When given a CoreDevice UUID, Build & Run first reads `devicectl device info details` for that device, checks that it reports the same UUID, and passes its hardware UDID to both xcodebuild invocations. If the UDID cannot be resolved it stops before building and asks for the hardware UDID. devicectl, which accepts either form, keeps the identifier you passed. Passing the hardware UDID avoids the extra query.

xcsift must be on PATH.

## Signing and provisioning (physical only)

By default, physical builds use the project's signing settings and only the certificates and provisioning profiles already on the Mac. Apple's developer services are not contacted. A new app, a new bundle identifier or a new device therefore fails to sign unless a matching development profile already exists.

Two opt-in options change that. **Both let Xcode act on your Apple developer account.**

| Option | Passes to `xcodebuild build` | Effect |
| --- | --- | --- |
| `--allow-provisioning-updates` | `-allowProvisioningUpdates` | xcodebuild talks to Apple's developer services with the account signed in under Xcode > Settings > Accounts. For automatically signed targets it may create and update certificates, app IDs and provisioning profiles; for manually signed targets it downloads missing or updated profiles. |
| `--allow-device-registration` | `-allowProvisioningDeviceRegistration` | Additionally lets xcodebuild register the destination device with the team. Requires `--allow-provisioning-updates`; xcodebuild ignores it otherwise, so Build & Run rejects it alone. |

Device registration is a separate option, as in xcodebuild, because it is a separate account change: it adds the device to the team's device list, which counts against the team's yearly device limit (a removed device keeps its slot until the membership year renews). A device that is already registered needs only `--allow-provisioning-updates`. For a phone the team has never used, pass both.

The options apply only to the build, not to the build-settings query, and change nothing else in the pipeline. Neither can choose a team: the project must set `DEVELOPMENT_TEAM`, and Xcode must have an account for that team. App Store Connect API keys (`-authenticationKey*`) are not exposed. Both options are rejected for simulator targets, which build without provisioning profiles. In MCP they are the optional booleans `allow_provisioning_updates` and `allow_device_registration` of `build_run`; an agent should ask before setting them.

## Execution

1. For a physical CoreDevice UUID, resolve the hardware UDID for xcodebuild's destination.
2. Query JSON build settings for the requested project, scheme, configuration and destination.
3. Resolve exactly one application target, its product path (`TARGET_BUILD_DIR`, which is `…/Build/Products/<configuration>-iphoneos` for an iPhone or `-appletvos` for an Apple TV) and bundle identifier. The destination is given to xcodebuild by its identifier alone, so the platform is the device's: an iPhone, an Apple TV, a watch, or a simulator of one. A device build is still refused for a simulator and a simulator build for a device.
4. Build into a new `tmp/build-run-<UUID>/` directory, adding the provisioning flags when requested.
5. Validate the app's Info.plist against its expected bundle ID, application package type and destination platform (`iPhoneOS` or `AppleTVOS` for a device, and so on for the other families).
6. Install it (`devicectl device install app` or `simctl install`), then launch with `--terminate-existing` (`--terminate-running-process` on a simulator), so a copy that is already running is stopped and the new build runs.

Build directories retain derived data, source-package state and raw `build.log`. Project scripts may write elsewhere according to their own configuration.

Every invocation uses an argument array. The merged Xcode log is passed to xcsift after build completion; diagnostics go to stderr. Xcode's exit status remains authoritative. Devicectl options precede the app operand so they are not forwarded as app arguments.

## Results and failures

Success returns JSON with `status: launched`, bundle identifier, app path, build directory and backend launch result. `verified: false` means app UI/continued health has not been checked. Follow with a screenshot, tree or app-specific assertion.

A failed build or product validation stops before install. Failed install stops before launch. Failed launch can leave an already-installed app. No rollback is promised.

When a physical build fails, Build & Run scans the raw log for known signing messages and appends the likely cause to the error, after the original message and raw log path: no development team, no Xcode account for the team, no development certificate, the device not registered or not in the profile, no matching profile, or a bundle identifier owned by another team. Where an option would help it names it, for example `rerun with --allow-provisioning-updates`. A log that matches none of these is reported unchanged. The hints are pattern matches on Xcode's wording and may miss reworded messages.

Dry-run returns the planned argument arrays without resolving an app, creating the build directory or querying a device: `buildSettingsArguments`, `buildArguments` (including any provisioning flags), and `installArguments`/`launchArguments` with placeholders for the app path and bundle identifier. Physical plans add a `provisioning` object stating which options are set and what they allow, and `destinationResolution` when a CoreDevice UUID will be resolved before the build.

## Verification and limits

Simulator project/Debug and workspace/Release flows were checked. On the iPhone 13 mini (Xcode 27.2, 27B52), with the [probe app](probe-app.md):

- The first `--allow-provisioning-updates` build failed at signing (no Xcode account, and the existing wildcard profile did not include the phone), and the appended hint named both causes.
- After the owner registered the phone with the team, the same command built, signed, installed and launched the app in about 12 seconds.
- Later, after an `uninstall`, a build without the option reinstalled and launched it with the existing profile.

`--allow-device-registration` and CoreDevice UUID resolution have not been run on hardware; they were checked against `xcodebuild -help`, `man xcodebuild` and `devicectl help`, dry runs and unit tests. See [verification](verification.md#touch-delivery-measured-with-the-probe-app).

Streaming progress, general cancellation coordination, a build deadline, reuse of earlier build directories, automatic symbolication and crash monitoring are unfinished. MCP `build_run` shares these limits. See [verification](verification.md) and the [roadmap](roadmap.md).
