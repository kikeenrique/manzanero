# Architecture and dependencies

`manzanero` has one Swift executable. The CLI and optional stdio MCP server both call `CommandService`, which validates requests, selects the backend and returns the operation's result.

## Execution boundaries

| Layer | Responsibility |
| --- | --- |
| CLI and MCP adapters | Parse arguments/schema, select an explicit target, format output |
| Shared command service | Route operations, apply preparation checks and in-process handoff pause |
| Native Swift code | Input schedules, AX/DTX parsing, screen analysis, media packet assembly and encoding |
| Linked `AppleDeviceBridge` target | Objective-C interoperability with installed Apple interfaces; socket and native-owner lifetimes |
| Apple executables | Xcode discovery, app/data operations, screenshots, simulator lifecycle and build/deploy |
| General-purpose Swift packages | MCP protocol support and scoped subprocess handling |

The Objective-C bridge is linked into the main process. It is not a helper executable. Private interfaces stay behind backend boundaries because their contracts and availability can change with Xcode or the OS.

Both process runners refuse non-Apple device-control executables, including AXe, idevice and ipb helpers. xcsift is allowed as a build-log formatter, not a device backend. The CLI no longer has any route that plans those helpers, and installing one does not bypass this policy.

## Build requirements

The executable targets macOS 26.6 and Apple silicon, and needs Xcode 27 or later selected: every device operation uses Xcode's tools (`devicectl`, `simctl`, `xcodebuild`) or the private frameworks that come with it, Xcode 27 has no Intel build, and it runs on macOS 26.6 or later. Before 2026-11-18 the manifest said macOS 15 and the release carried an x86_64 slice that could never have worked. `doctor`'s `Requirements` entry reports an older Xcode or macOS as `unavailable`. Swift language mode is 6 with strict concurrency; the manifest's tools floor is 6.2, while the resolved `swift-collections` dependency requires Swift 6.4+ to build the current graph.

Use a full Xcode installation selected as the active developer directory. Command Line Tools alone do not supply the physical-device services. Development tasks use mise and xcsift:

```sh
mise run build
mise run test
```

Build products live under `.build/`; task caches and working files use `tmp/`, which is untracked, not ignored, and disposable. See [development tasks](development-tasks.md).

## Linked packages

[Package.swift](../Package.swift) declares four direct packages; [Package.resolved](../Package.resolved) records the complete resolved graph.

| Package | Pin | Purpose |
| --- | --- | --- |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | 1.8.2, `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Command-line parsing, generated help and shell completion |
| [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1, `a0ae212ebf6eab5f754c3129608bc5557637e605` | Optional MCP mode in the standard executable |
| [Swift Subprocess](https://github.com/swiftlang/swift-subprocess) | 1.0.2, `dbe21bd7dfd4ffef8c32588918542a8abfa1b54c` | Scoped asynchronous process output, cancellation and reaping |

| [lwIP](https://github.com/kikeenrique/lwip), the human owner's fork, branch `swift-package-main` | `2.2.1-swiftpm-dev.1`, `728f189b05d02d3562a084baa96e2abacdd4404b` | TCP over IPv6 in user space, for [the tool's own tunnel](transport.md#a-tunnel-of-the-tools-own) to a device, whose packets the tool carries itself. Authorized by the human owner on 2026-11-19. BSD licence: [notice](../ThirdParty/lwip-LICENSE.txt) |

lwIP is C, configured when it is compiled, and its own repository has no Swift package manifest, so this project depends on a fork that adds one. The fork is [lwIP's GitHub mirror](https://github.com/lwip-tcpip/lwip) plus one commit: a `Package.swift`, and under `swiftpm/` a configuration for one job (`port/lwipopts.h`: IPv6 and TCP only, no threads, the system allocator), a platform header for macOS, and a small C surface (`include/CLwIP.h`, prefix `ADL`). lwIP's own sources are unchanged there; none of them is in this repository.

Two branches exist on the fork. `swift-package-main`, the one pinned here, sits on lwIP's main branch as of 2026-11-17, the development of 2.2.2, which carries TCP fixes made after the last release. `swift-package` (`2.2.1-swiftpm.1`) sits on the 2.2.1 release. To take a newer lwIP: merge or rebase the branch onto it in the fork, tag, and change the version here. To work on the port while building this tool against a local copy, `swift package edit lwip` and, when done, `swift package unedit lwip`.

The product exposes none of lwIP's headers, only `CLwIP.h`. lwIP's structures change shape with its options, a client that included its headers would have to be compiled with the same ones, and a package's C settings are not passed on to the packages that depend on it. For the same reason the configuration is not offered as package traits ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)): a trait does switch a C define inside a dependency, which was tried here, but with only that surface exposed there is nothing for one to switch yet. lwIP keeps its state in globals, so a process has one stack and every call is made from one thread.

The MCP SDK also resolves packages used by its other products; resolution alone does not prove every package is compiled into this executable. Swift Subprocess does not implement device protocols. Existing synchronous paths still use `ToolRunner`; streaming paths use `StreamingToolRunner`.

Swift Argument Parser parses the CLI's arguments only; it runs no command itself, and the CLI keeps its own exit path, error format and signal handling.

Preserve the [Argument Parser license](../ThirdParty/swift-argument-parser-LICENSE.txt), [MCP license/transition notice](../ThirdParty/swift-mcp-sdk-LICENSE.txt), [Subprocess license](../ThirdParty/swift-subprocess-LICENSE.txt), [lwIP license](../ThirdParty/lwip-LICENSE.txt) and applicable transitive notices when distributing binaries. Packaging gathers notices from the resolved source graph.

## Apple interfaces

- `devicectl` and `simctl` handle discovery, app/lifecycle/data operations and capture wrappers.
- CoreDevice/RemoteXPC provide physical button, keyboard, Indigo digitizer and Universal HID dispatch.
- Network/RemoteXPC and raw AX DTX provide native physical accessibility.
- CoreSimulator, libxpc's simulator endpoint functions and AccessibilityPlatformTranslation provide [simulator input and accessibility](simulator-input.md): Indigo HID to the simulator's `dtuhidd`, and archived `AXPTranslatorRequest` objects through `-[SimDevice sendAccessibilityRequestAsync:…]`.
- Vision provides OCR.
- AVConference negotiation, standard RTP/HEVC parsing, VideoToolbox decoding, CoreImage buffer copying and AVFoundation encoding provide explicit native physical recording.

No Apple device framework is redistributed. Runtime use depends on what the host's installed Apple software exposes. A successful build is not proof that a private interface works on a particular device.

### Dynamically resolved interfaces

The bridge resolves private interfaces lazily inside each operation (`dlopen`, `dlsym`, class and selector checks). The single list of them is the capability table in [`AppleInterfaceAvailability.m`](../Sources/AppleDeviceBridge/AppleInterfaceAvailability.m), exposed as `ADCCheckCapabilities`. The operations keep their own guards; when a guard changes, update the table too.

Shared groups:

- **CoreDevice preparation** (`ADCPrepareCoreDevice`): framework `/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice` (`RTLD_NOW | RTLD_GLOBAL`), symbols `_coredevice_xpc_add_bundle`, `_coredevice_xpc_init_services`.
- **RemoteXPC descriptor control**: `xpc_remote_connection_create_with_connected_fd`, `xpc_remote_connection_set_event_handler`, `xpc_remote_connection_activate`, `xpc_remote_connection_cancel`.
- **Media control** (`ADCMediaControl`): CoreDevice preparation + descriptor control + `xpc_remote_connection_send_message_with_reply`.
- **CoreSimulator device lookup** (`ADCPrepareCoreSimulator`, `ADCOpenSimulatorDevice`): framework `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator` (`RTLD_NOW | RTLD_GLOBAL`); `SimServiceContext` with `+sharedServiceContextForDeveloperDir:error:` and `-defaultDeviceSetWithError:`; `-[SimDeviceSet devicesByUDID]`; `-[SimDevice stateString]`, `-deviceType`, `-lookup:error:`; `-[SimDeviceType mainScreenSize]`, `-mainScreenScale`. The developer directory is `DEVELOPER_DIR` or `xcode-select -p`.
- **AVConference negotiation**: framework `/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference` (`RTLD_NOW | RTLD_LOCAL`); classes `AVCMediaStreamNegotiator`, `AVCMediaStreamNegotiatorSettings`, `AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing`; `-[AVCMediaStreamNegotiator initWithMode:options:error:]`, `-negotiatorSettings`, `-createOffer`, `-offer`, `-setAnswer:withError:`, `-generateMediaStreamConfigurationWithError:`, `-generateMediaStreamInitOptionsWithError:`; `+[AVCMediaStreamNegotiatorSettings negotiatorSettingsForMode:deviceRole:options:errorString:]`, `-[AVCMediaStreamNegotiatorSettings localSSRC]`. The five selectors from `createOffer` on are called without an operation guard, so doctor is the only advance check for them. For `record --audio` the same negotiator is made a second time with the settings class `AVCMediaStreamNegotiatorSettingsCoreDeviceSystemAudio`, and `+[VCPayloadUtils sampleRateForPayload:]` gives the stream's sample rate; both are optional in doctor's table, and their absence fails a recording with sound before any stream starts. The sound itself is decoded and written with public AudioToolbox and AVFoundation.

| Capability (doctor `name`) | Commands | Requires | Optional |
| --- | --- | --- | --- |
| `physical-input` | `button`, `wake`, `key`, `type`, `detect-layout` (with `rsd-accessibility`), `paste`, `tap`, `long-press`, `drag`, `swipe`, `pinch`, two-contact `multi-drag` (Indigo HID) | CoreDevice preparation, descriptor control, `xpc_remote_connection_send_message`, `xpc_remote_connection_send_message_with_reply` | — |
| `multi-contact-input` | `gesture`, `multi-tap`, three-to-five-path `multi-drag`, and `remote swipe-*` on a physical Apple TV (Universal HID) | Same as `physical-input` | — |
| `tunnel-assertion` | Native AX, native recording and `frames` | Nothing dynamic: public XPC to the pairing daemon, which doctor does not contact | — |
| `rsd-accessibility` | `tree`, `press`, `scroll`, `wait`, `set-value` | CoreDevice preparation, `xpc_remote_connection_create_with_nw_connection`, `_setup_nw_parameters`, `_get_failsafe_version_flags`, `_cancel`, `_set_event_handler`, `_activate`, `_send_message` | — |
| `rsd-log-relay` | physical `logs` | The same as `rsd-accessibility` | — |
| `accessibility-shim` | `press` on a physical Apple TV by the Inspector's cursor, tried before the route over Apple's tunnel ([guide](other-families.md#press-by-the-inspectors-cursor)): the device's accessibility daemon reached through the Mac's own `remoted` ([state](transport.md#the-cost-of-this-route)) | The RemoteServiceDiscovery framework (`/System/Library/PrivateFrameworks/RemoteServiceDiscovery.framework/RemoteServiceDiscovery`, `RTLD_NOW`) and `remote_device_copy_device_with_uuid`; the MobileDevice framework (`RTLD_NOW \| RTLD_GLOBAL`) and `AMDeviceCreateWithRemoteDeviceWithError`, `AMDeviceConnect`, `AMDeviceStartSession`, `AMDeviceStopSession`, `AMDeviceDisconnect`, `AMDeviceSecureStartService`, `AMDServiceConnectionGetSocket`, `AMDServiceConnectionGetSecureIOContext`, `AMDServiceConnectionInvalidate` | — |
| `device-tunnel` | `tree`, `press`, `scroll`, `wait`, `set-value` on a device on its cable or on the network, unless `MANZANERO_OWN_TUNNEL=0` ([the tool's own tunnel](transport.md#a-tunnel-of-the-tools-own)) | The MobileDevice framework (`/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice`, `RTLD_NOW \| RTLD_GLOBAL`) and `AMDCreateDeviceList`, `AMDeviceCopyDeviceIdentifier`, `AMDeviceGetInterfaceType`, `AMDeviceGetConnectionID`, `AMDeviceCreateFromProperties`, `AMDeviceConnect`, `AMDeviceValidatePairing`, `AMDeviceStartSession`, `AMDeviceStopSession`, `AMDeviceDisconnect`, `AMDeviceSecureStartService`, `AMDServiceConnectionSend`, `AMDServiceConnectionReceive`, `AMDServiceConnectionInvalidate`. lwIP is linked in, not resolved | — |
| `media-inspection` | `media-status` | Media control | — |
| `native-recording` | `record --backend coredevice` and `frames` (packet mode); on an Apple TV the offer is made again without resolution adaptation, through the negotiator's local video configuration (optional interfaces: without them a capture there fails before any stream starts) | Media control, AVConference negotiation | `-[AVCMediaStreamNegotiator mediaNegotiator]`, `VCMediaNegotiatorBase` and `-negotiatedScreenSettings`, `VCMediaNegotiatorResultsVideo` and `-isRTCPFBEnabled` (RTCP feedback stays unknown without them) |
| `simulator-input` | Simulator `tap`, `long-press`, `swipe`, `drag`, `pinch`, `multi-tap`, `multi-drag`, `gesture`, `button`, `remote`, `crown`, `key`, `type`, `detect-layout` (with `simulator-accessibility`) | CoreSimulator device lookup, `xpc_endpoint_create_mach_port_4sim`, `xpc_connection_create_from_endpoint`, `xpc_connection_enable_sim2host_4sim`, and the existence of CoreSimulator's `Platforms/iphoneos/Library/LaunchDaemons/com.apple.coredevice.dtuhidd.plist` | `-[SimDevice name]` |
| `simulator-hinge` | Simulator `fold`, `unfold`, `hinge` (iPhone Duo; the read uses CoreDevice's `streamhingeangle` action on `dtdeviceinfod`) | CoreSimulator device lookup, the three `_4sim`/endpoint symbols as for `simulator-input`, `-[SimDevice UDID]`, and the existence of the `dtuhidd` and `dtdeviceinfod` launchd plists. `IOCFSerialize` is linked public IOKit API | `-[SimDevice name]` |
| `simulator-accessibility` | Simulator `tree`, `press`, `scroll`, `wait`, `set-value` | CoreSimulator device lookup, `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`, framework `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation` (`RTLD_NOW | RTLD_LOCAL`), classes `AXPTranslatorRequest`, `AXPTranslatorResponse`, `AXPTranslationObject`, each with `+supportsSecureCoding` | `-[SimDevice name]` |
| `keyed-archive-uid` | AX archives, `decode-ax-archive` | `_CFKeyedArchiverUIDGetTypeID`, `_CFKeyedArchiverUIDGetValue` (linked CoreFoundation) | — |
The check loads each framework with the operation's own path and flags, which runs the image's initializers, and then only looks names up (a file requirement is an existence check that neither opens nor parses the file): `dlsym(RTLD_DEFAULT, …)`, `objc_lookUpClass` and a walk of `class_copyMethodList` up the superclass chain. It never calls a resolved function (in particular not the two CoreDevice initialisers), sends no message to a checked class (so no `+initialize` or dynamic method resolution runs), opens no connection and contacts no device. A method provided only through dynamic resolution would be reported missing although `respondsToSelector:` accepts it; none of the listed methods is known to work that way.

`rsd-log-relay` is physical `logs` ([app logs](app-logs.md#physical-devices)): the lockdown shim route (`ADCCopyRSDShimServicePort`, `RSDDirectoryConnection.shimServicePort`), which resolves nothing dynamically beyond what `rsd-accessibility` lists, so its row shows the same interfaces.

### Reading doctor output

`manzanero doctor` prints one JSON array. Each entry has `name`, `kind` and `status`:

- `kind: "tool"` — the original `Xcode`, `CoreDevice` (`devicectl`) and `CoreSimulator` (`simctl`) entries, with `status` `available` or `unavailable` (plus `detail`).
- `kind: "host"` — `name: "Host"`, `status: "reported"`, with `macOSVersion`, `macOSBuild`, `xcodeVersion`, `xcodeBuild` (parsed from `xcodebuild -version`), `coreDeviceVersion` and `avConferenceVersion` (the frameworks' `CFBundleVersion`, read from `Info.plist` without loading code). Values that cannot be read are omitted.
- `kind: "requirement"` — `name: "Requirements"`, with `minimumXcode` ("27"), `minimumMacOS` ("26.6") and `architecture` ("arm64"). `status` is `available` when the selected Xcode and the host's macOS meet the minimums, `unavailable` with a `detail` naming what is older (select a newer Xcode with `xcode-select` or `DEVELOPER_DIR`), or `unknown` when the Xcode version could not be read. The macOS line can only fail for a build made with another deployment target, because this executable does not load below 26.6.
- `kind: "host-network"` — `name: "Firewall"`, read from Apple's `socketfilterfw`: `status` is `off`, `allowed`, `blocked`, `no-rule` or `unknown`, with the resolved `executable` path, a `detail`, `affects: ["native-recording"]` and, when incoming video would be dropped, an `action`. It never changes the exit code. See [recording](recording.md#the-macos-firewall-can-drop-the-video).
- `kind: "private-interface"` — one entry per capability above, with `summary`, `usedByCommands`, `checked` (number of interfaces checked), `missing` and `optionalMissing` (exact names: framework path, symbol, class, file path, or `-[Class selector]` / `+[Class selector]`), and `minimumMacOS` where one applies (only `native-recording` has one, 26, which the executable's own 26.6 floor has made redundant, so `unsupported-host` no longer occurs). `status` is `available`, `degraded` (only optional names missing), `missing` (a required name is missing; that capability's commands will fail) or `unsupported-host` (the host macOS is below `minimumMacOS`, explained in `detail`; missing names are still listed).

The exit code is 1 only when an entry has status `unavailable`, which the tool entries and the `Requirements` entry use: without the three Apple tools, or with an Xcode older than 27, nothing works. Private-interface gaps keep exit code 0 (and MCP `isError: false`): each one disables a subset of commands, the rest of the product still works, and a host that uses only `devicectl`/`simctl` wrappers needs none of them. A non-zero exit for an optional capability would make doctor useless as a gate. Scripts that need a capability should test its entry's `status`. All results describe this host only; an `available` capability is not proof that the device accepts the operation.

ffmpeg is not a dependency and no command runs it. On 2026-11-20 its `ffprobe` and software decoder were used once, by hand, to read a kept video file on the Mac as a second opinion on this tool's decoding ([record](verification.md#a-second-decoder-and-videotoolboxs-resolution-adaptation)).

## Implementation references and attribution

Third-party device projects inform protocol understanding; their executables are not runtime dependencies.

| Reference | Pinned revision | Use |
| --- | --- | --- |
| [ipb](https://github.com/ipbtools/ipb) | `8c227a10710dad479852aa0203de729fed57471b` | AX requests, HID and native media research; [MIT notice](../ThirdParty/ipb-LICENSE.txt) |
| [idevice](https://github.com/jkcoxson/idevice) | `89702099f4d7552f704f93b4526756abda319ceb` | Reference for the earlier Rust bridge and its HID/DTX work, both removed |
| [idevice](https://github.com/jkcoxson/idevice), `idevice/src/remote_pairing/` | `2dca9a58a9a1dd02ec7d6213fcfd8fe861e74132` | The remote pairing conversation behind `pair` and the paired tunnel ([transport](transport.md#a-pairing-of-the-tools-own)): the messages, their order, the key labels and the TLV and OPACK forms were read from it and written again in Swift, with no source copied and no runtime added; [MIT notice](../ThirdParty/idevice-LICENSE.txt) |
| [idevice-srp](https://github.com/jkcoxson/idevice-srp) | `5f9e56017f60a6eac95b7e19876409ca3c914f2f` | How each SRP hash input is written (padding of the public values, the group) for `PairingSRP`; written again in Swift; [MIT notice](../ThirdParty/idevice-srp-LICENSE.txt) |
| [AXe](https://github.com/cameroncooke/AXe) | `4b622d4436fc441534e6ee8c7196728cd762dbff` | Physical media/AX review, RTCP layout/statistics and the simulator `dtuhidd`/AX routes; [MIT notice](../ThirdParty/AXe-LICENSE.txt) |
| [IDB](https://github.com/facebook/idb) (`FBSimulatorControl`, vendored by AXe at the revision above) | AXe's `Packages/IDBKit` | Simulator DTUHID transport reference: the `_4sim` connection setup and the 380 ms drain before disconnect; [MIT notice](../ThirdParty/IDB-LICENSE.txt) |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | `03d788d23105c1754c27cc4e6ddc1d7e23835b32` | Native tunnel/RSD interoperability research, and its notes on the audit service behind the accessibility shim (the cursor moves and their directions, read on 2026-11-20); no source copied or runtime added |

The receiver-report code was informed by AXe's `PhysicalDisplayRTCP.swift` and RFC 3550. The simulator bridge (`AppleSimulatorBridge.m`) was written from this project's own experiments ([research](simulator-input-research.md)); the only value taken from IDB's `FBSimulatorDTUHIDTransport.swift` is its measured 380 ms drain, and no source was copied. [The reference review](axe-physical-review.md) distinguishes those findings from live behavior.

No proprietary device-control binary is linked or packaged. Required open-source attribution is retained in `ThirdParty/`.

## Retired helpers

The AXe, Rust idevice and ipb helper backends have been removed: first their CLI and MCP routes, planners, dry-run plans and tests, then their sources, patches and build tasks. Git history keeps them. What went with them:

- independent `pair wifi` and `--pairing-file` device operations (no longer recognised as commands);
- `--physical-backend idevice` (the backend option itself is gone: `coredevice` is the only physical backend);
- `hid-info` and raw live `ax-snapshot` with its archive saving (no longer commands), and the helper-based finite physical `logs` (physical `logs` now reads the device's log relay in process; see [app logs](app-logs.md#physical-devices));
- AXe-backed simulator input and hierarchy (replaced by the in-process [simulator route](simulator-input.md));
- the old ipb input helper plans (`coredevice-ipb` dry runs) and its video helper with the ADV1 JPEG pipe.

`DeviceExecutablePolicy` remains as the runtime guarantee. Earlier successes or failures from those routes are historical evidence, not current setup instructions. The old idevice HID path could use stop-all media cleanup and returned receipts without visible input effects; it must not be substituted for the current owned native operations.
