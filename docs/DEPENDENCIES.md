# Architecture and dependencies

`appledevicescmd` has one Swift executable. The CLI and optional stdio MCP server both call `CommandService`, which validates requests, selects the backend and returns the operation's result.

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

Both process runners refuse non-Apple device-control executables, including AXe, idevice and ipb helpers. xcsift is allowed as a build-log formatter, not a device backend. Installing a legacy helper or selecting an old backend does not bypass this policy.

## Build requirements

The executable targets macOS 15+. Native video needs macOS 26+. Swift language mode is 6 with strict concurrency; the manifest's tools floor is 6.2, while the resolved `swift-collections` dependency requires Swift 6.4+ to build the current graph.

Use a full Xcode installation selected as the active developer directory. Command Line Tools alone do not supply the physical-device services. Development tasks use mise and xcsift:

```sh
mise run build
mise run test
```

Build products live under `.build/`; task caches and investigation artifacts use ignored `tmp/`. See [development tasks](DEVELOPMENT-TASKS.md).

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

## Implementation references and attribution

Third-party device projects inform protocol understanding; their executables are not runtime dependencies.

| Reference | Pinned revision | Use |
| --- | --- | --- |
| [ipb](https://github.com/ipbtools/ipb) | `8c227a10710dad479852aa0203de729fed57471b` | AX requests, HID and native media research; [MIT notice](../ThirdParty/ipb-LICENSE.txt) |
| [idevice](https://github.com/jkcoxson/idevice) | `89702099f4d7552f704f93b4526756abda319ceb` | Earlier Rust implementation and HID/DTX references; [MIT notice](../ThirdParty/idevice-LICENSE.txt) |
| [AXe](https://github.com/cameroncooke/AXe) | `4b622d4436fc441534e6ee8c7196728cd762dbff` | Physical media/AX review and RTCP layout/statistics; [MIT notice](../ThirdParty/AXe-LICENSE.txt) |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | `03d788d23105c1754c27cc4e6ddc1d7e23835b32` | Native tunnel/RSD interoperability research; no source copied or runtime added |

The receiver-report code was informed by AXe's `PhysicalDisplayRTCP.swift` and RFC 3550. [The reference review](AXE-PHYSICAL-REVIEW.md) distinguishes those findings from live behavior.

No proprietary device-control binary is linked or packaged. Required open-source attribution is retained in `ThirdParty/`.

## Retired helpers

`Backends/IDevice` and `Backends/CoreDevice` retain earlier Rust/native adapters and patches as migration references. Their build tasks can reproduce research artifacts, but the product refuses those executables. In particular, these routes are currently unavailable:

- independent `pair wifi` / `--pairing-file` device operations;
- `hid-info`, raw live `ax-snapshot` and finite physical `logs`;
- AXe-backed simulator input and hierarchy;
- the old ipb input/video helper and its ADV1 JPEG pipe.

Earlier successes or failures from those routes are historical evidence, not current setup instructions. The old idevice HID path could use stop-all media cleanup and returned receipts without visible input effects; it must not be substituted for the current owned native operations.
