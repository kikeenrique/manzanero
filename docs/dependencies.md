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

The executable targets macOS 15+. Native video needs macOS 26+. Swift language mode is 6 with strict concurrency; the manifest's tools floor is 6.2, while the resolved `swift-collections` dependency requires Swift 6.4+ to build the current graph.

Use a full Xcode installation selected as the active developer directory. Command Line Tools alone do not supply the physical-device services. Development tasks use mise and xcsift:

```sh
mise run build
mise run test
```

Build products live under `.build/`; task caches and investigation artifacts use ignored `tmp/`. See [development tasks](development-tasks.md).

## Linked packages

[Package.swift](../Package.swift) declares two direct packages; [Package.resolved](../Package.resolved) records the complete resolved graph.

| Package | Pin | Purpose |
| --- | --- | --- |
| [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1, `a0ae212ebf6eab5f754c3129608bc5557637e605` | Optional MCP mode in the standard executable |
| [Swift Subprocess](https://github.com/swiftlang/swift-subprocess) | 1.0.2, `dbe21bd7dfd4ffef8c32588918542a8abfa1b54c` | Scoped asynchronous process output, cancellation and reaping |

The MCP SDK also resolves packages used by its other products; resolution alone does not prove every package is compiled into this executable. Swift Subprocess does not implement device protocols. Existing synchronous paths still use `ToolRunner`; streaming paths use `StreamingToolRunner`.

Preserve the [MCP license/transition notice](../ThirdParty/swift-mcp-sdk-LICENSE.txt), [Subprocess license](../ThirdParty/swift-subprocess-LICENSE.txt) and applicable transitive notices when distributing binaries. Packaging gathers notices from the resolved source graph.

## Apple interfaces

- `devicectl` and `simctl` handle discovery, app/lifecycle/data operations and capture wrappers.
- CoreDevice/RemoteXPC provide physical button, keyboard, Indigo digitizer and Universal HID dispatch.
- Network/RemoteXPC and raw AX DTX provide native physical accessibility.
- Vision provides OCR.
- AVConference negotiation, standard RTP/HEVC parsing, VideoToolbox decoding, CoreImage buffer copying and AVFoundation encoding provide explicit native physical recording.

No Apple device framework is redistributed. Runtime use depends on what the host's installed Apple software exposes. A successful build is not proof that a private interface works on a particular device.

### Dynamically resolved interfaces

The bridge resolves private interfaces lazily inside each operation (`dlopen`, `dlsym`, class and selector checks). The single list of them is the capability table in [`AppleInterfaceAvailability.m`](../Sources/AppleDeviceBridge/AppleInterfaceAvailability.m), exposed as `ADCCheckCapabilities`. The operations keep their own guards; when a guard changes, update the table too.

Shared groups:

- **CoreDevice preparation** (`ADCPrepareCoreDevice`): framework `/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice` (`RTLD_NOW | RTLD_GLOBAL`), symbols `_coredevice_xpc_add_bundle`, `_coredevice_xpc_init_services`.
- **RemoteXPC descriptor control**: `xpc_remote_connection_create_with_connected_fd`, `xpc_remote_connection_set_event_handler`, `xpc_remote_connection_activate`, `xpc_remote_connection_cancel`.
- **Media control** (`ADCMediaControl`): CoreDevice preparation + descriptor control + `xpc_remote_connection_send_message_with_reply`.
- **AVConference negotiation**: framework `/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference` (`RTLD_NOW | RTLD_LOCAL`); classes `AVCMediaStreamNegotiator`, `AVCMediaStreamNegotiatorSettings`, `AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing`; `-[AVCMediaStreamNegotiator initWithMode:options:error:]`, `-negotiatorSettings`, `-createOffer`, `-offer`, `-setAnswer:withError:`, `-generateMediaStreamConfigurationWithError:`, `-generateMediaStreamInitOptionsWithError:`; `+[AVCMediaStreamNegotiatorSettings negotiatorSettingsForMode:deviceRole:options:errorString:]`, `-[AVCMediaStreamNegotiatorSettings localSSRC]`. The five selectors from `createOffer` on are called without an operation guard, so doctor is the only advance check for them.

| Capability (doctor `name`) | Commands | Requires | Optional |
| --- | --- | --- | --- |
| `physical-input` | `button`, `key`, `type`, `paste`, `tap`, `long-press`, `drag`, `swipe`, `pinch`, two-contact `multi-drag` (Indigo HID) | CoreDevice preparation, descriptor control, `xpc_remote_connection_send_message`, `xpc_remote_connection_send_message_with_reply` | — |
| `multi-contact-input` | `gesture`, `multi-tap`, three-to-five-path `multi-drag` (Universal HID) | Same as `physical-input` | — |
| `tunnel-assertion` | Native AX and native recording | Nothing dynamic: public XPC to the pairing daemon, which doctor does not contact | — |
| `rsd-accessibility` | `tree`, `press-id`/`-label`, `scroll-id`/`-label` | CoreDevice preparation, `xpc_remote_connection_create_with_nw_connection`, `_setup_nw_parameters`, `_get_failsafe_version_flags`, `_cancel`, `_set_event_handler`, `_activate`, `_send_message` | — |
| `media-inspection` | `media-status` | Media control | — |
| `native-recording` (macOS 26+) | `record-screen --recording-backend coredevice` (packet mode) | Media control, AVConference negotiation | `-[AVCMediaStreamNegotiator mediaNegotiator]`, `VCMediaNegotiatorBase` and `-negotiatedScreenSettings`, `VCMediaNegotiatorResultsVideo` and `-isRTCPFBEnabled` (RTCP feedback stays unknown without them) |
| `keyed-archive-uid` | AX archives, `decode-ax-archive` | `_CFKeyedArchiverUIDGetTypeID`, `_CFKeyedArchiverUIDGetValue` (linked CoreFoundation) | — |
| `native-recording-jpeg` (macOS 26+) | none (`ADCCreateVideoSession`) | Media control, AVConference negotiation, `AVCVideoStream` (`-initWithNetworkSockets:options:error:`, `-configure:error:`, `-setDelegate:`, `-start`, `-stop`, `-streamToken`), `AVCStreamOutput` (`-initWithStreamToken:delegate:queue:error:`, `-setDelegate:`, `-validateAccess`) | — |

The check loads each framework with the operation's own path and flags, which runs the image's initializers, and then only looks names up: `dlsym(RTLD_DEFAULT, …)`, `objc_lookUpClass` and a walk of `class_copyMethodList` up the superclass chain. It never calls a resolved function (in particular not the two CoreDevice initialisers), sends no message to a checked class (so no `+initialize` or dynamic method resolution runs), opens no connection and contacts no device. `AVCStreamOutput`'s runtime access validator needs an instance and is not run. A method provided only through dynamic resolution would be reported missing although `respondsToSelector:` accepts it; none of the listed methods is known to work that way.

### Reading doctor output

`manzanero doctor` prints one JSON array. Each entry has `name`, `kind` and `status`:

- `kind: "tool"` — the original `Xcode`, `CoreDevice` (`devicectl`) and `CoreSimulator` (`simctl`) entries, with `status` `available` or `unavailable` (plus `detail`).
- `kind: "host"` — `name: "Host"`, `status: "reported"`, with `macOSVersion`, `macOSBuild`, `xcodeVersion`, `xcodeBuild` (parsed from `xcodebuild -version`), `coreDeviceVersion` and `avConferenceVersion` (the frameworks' `CFBundleVersion`, read from `Info.plist` without loading code). Values that cannot be read are omitted.
- `kind: "host-network"` — `name: "Firewall"`, read from Apple's `socketfilterfw`: `status` is `off`, `allowed`, `blocked`, `no-rule` or `unknown`, with the resolved `executable` path, a `detail`, `affects: ["native-recording"]` and, when incoming video would be dropped, an `action`. It never changes the exit code. See [recording](recording.md#the-macos-firewall-can-drop-the-video).
- `kind: "private-interface"` — one entry per capability above, with `summary`, `usedByCommands`, `checked` (number of interfaces checked), `missing` and `optionalMissing` (exact names: framework path, symbol, class, or `-[Class selector]` / `+[Class selector]`), and `minimumMacOS` where one applies. `status` is `available`, `degraded` (only optional names missing), `missing` (a required name is missing; that capability's commands will fail) or `unsupported-host` (the host macOS is below `minimumMacOS`, explained in `detail`; missing names are still listed).

The exit code is 1 only when an entry has status `unavailable`, which only tool entries use, so the original rule is unchanged. Private-interface gaps keep exit code 0 (and MCP `isError: false`): each one disables a subset of commands, the rest of the product still works, and a host that uses only `devicectl`/`simctl` wrappers needs none of them. A non-zero exit for an optional capability would make doctor useless as a gate. Scripts that need a capability should test its entry's `status`. All results describe this host only; an `available` capability is not proof that the device accepts the operation.

## Implementation references and attribution

Third-party device projects inform protocol understanding; their executables are not runtime dependencies.

| Reference | Pinned revision | Use |
| --- | --- | --- |
| [ipb](https://github.com/ipbtools/ipb) | `8c227a10710dad479852aa0203de729fed57471b` | AX requests, HID and native media research; [MIT notice](../ThirdParty/ipb-LICENSE.txt) |
| [idevice](https://github.com/jkcoxson/idevice) | `89702099f4d7552f704f93b4526756abda319ceb` | Earlier Rust implementation and HID/DTX references; [MIT notice](../ThirdParty/idevice-LICENSE.txt) |
| [AXe](https://github.com/cameroncooke/AXe) | `4b622d4436fc441534e6ee8c7196728cd762dbff` | Physical media/AX review and RTCP layout/statistics; [MIT notice](../ThirdParty/AXe-LICENSE.txt) |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | `03d788d23105c1754c27cc4e6ddc1d7e23835b32` | Native tunnel/RSD interoperability research; no source copied or runtime added |

The receiver-report code was informed by AXe's `PhysicalDisplayRTCP.swift` and RFC 3550. [The reference review](axe-physical-review.md) distinguishes those findings from live behavior.

No proprietary device-control binary is linked or packaged. Required open-source attribution is retained in `ThirdParty/`.

## Retired helpers

The AXe, Rust idevice and ipb helper backends have been removed: first their CLI and MCP routes, planners, dry-run plans and tests, then their sources, patches and build tasks. Git history keeps them. What went with them:

- independent `pair wifi` and `--pairing-file` device operations (no longer recognised as commands);
- `--physical-backend idevice` (now an unsupported backend; `coredevice` is the only physical backend and the default);
- `hid-info`, raw live `ax-snapshot` with its archive saving, and finite physical `logs` (now unsupported physical-device operations);
- AXe-backed simulator input and hierarchy (now refused as not available yet; simulator `screen` uses OCR);
- the old ipb input helper plans (`coredevice-ipb` dry runs) and its video helper with the ADV1 JPEG pipe.

`DeviceExecutablePolicy` remains as the runtime guarantee. Earlier successes or failures from those routes are historical evidence, not current setup instructions. The old idevice HID path could use stop-all media cleanup and returned receipts without visible input effects; it must not be substituted for the current owned native operations.
