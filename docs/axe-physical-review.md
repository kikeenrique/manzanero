# AXe physical-backend review

Source reviewed on 2026-11-12 at [revision `4b622d4436fc441534e6ee8c7196728cd762dbff`](https://github.com/cameroncooke/AXe/tree/4b622d4436fc441534e6ee8c7196728cd762dbff). This was source research, not an AXe device test. No AXe executable is used by the product.

## Design ideas relevant here

| AXe area | Useful idea | manzanero gap or application |
| --- | --- | --- |
| Input owner/broker | Track held input across clients, attempt release, block later input after uncertain cleanup | Cross-process ownership/quarantine remains missing here |
| Display stream | Own session UUID/control/UDP lifetime; poll disappearance of the owned session rather than stop-all | Informed session-specific media cleanup; independent teardown proof still limited |
| Negotiated transport | Validate endpoints, codec/RTCP metadata and distinguish stall/replacement | Scoped validations exist; broad long-session/recovery behavior remains incomplete |
| Screenshot capture | Check geometry before/after each capture | Distinct from stream timing/quality; not a silent substitute |
| H.264 stream | Native access-unit pass-through | Different from this project's HEVC decode/AVFoundation encode route |
| Readiness/gestures | Check lock/service metadata and coordinate/selector guards | Reference designs, not proof of our device behavior |

Representative sources are [input owner](https://github.com/cameroncooke/AXe/blob/4b622d4436fc441534e6ee8c7196728cd762dbff/Sources/AXe/Device/PhysicalDeviceInputOwner.swift), [display stream](https://github.com/cameroncooke/AXe/blob/4b622d4436fc441534e6ee8c7196728cd762dbff/Sources/AXe/Device/PhysicalDeviceDisplayStream.swift) and [media capture](https://github.com/cameroncooke/AXe/blob/4b622d4436fc441534e6ee8c7196728cd762dbff/Sources/AXe/Device/PhysicalDeviceMediaCapture.swift).

## Dependency decision

AXe exports `AXeCore`, but the reviewed physical backend lives in its executable target and expects locally built IDB frameworks. Adding the repository URL alone would not expose a supported physical-backend library.

The project instead implements device operations against Apple APIs in its own code. General-purpose packages remain appropriate where useful; another device CLI is not the intended runtime boundary.

## Actual reuse and attribution

The RTCP receiver-report layout/statistics were informed by AXe's [PhysicalDisplayRTCP.swift](https://github.com/cameroncooke/AXe/blob/4b622d4436fc441534e6ee8c7196728cd762dbff/Sources/AXe/Device/PhysicalDisplayRTCP.swift) and RFC 3550. The [MIT notice](../ThirdParty/AXe-LICENSE.txt) is retained.

Native HEVC reception uses Apple's negotiator, not AXe's custom offer encoder. Receiver reports and scoped recordings have local/live evidence here; no AXe runtime operation was invoked. Keyframe/crash recovery and cross-process coordination remain separate gaps. See [recording](recording.md) and [verification](verification.md).
