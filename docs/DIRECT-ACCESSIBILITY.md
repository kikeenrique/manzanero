# Direct physical accessibility migration

Physical accessibility remains unavailable in the current product runtime: the former idevice executable is disabled. The replacement must operate in `appledevicescmd` against Apple interfaces, without launching an intermediary. This page tracks implementation separately from live device evidence.

## DTX framing

`AccessibilityDTX` implements bounded framing for `com.apple.accessibility.axAuditDaemon.remoteAXService`. The service carries DTX rather than the RemoteXPC HID dictionary protocol. It preserves keyed archive bytes without instantiating device-specified classes; semantic archive decoding and normalized trees are separate unfinished layers.

The codec limits a combined body to 16 MiB and a message to 64 fragments. A fragmented message's initial header declares combined size without carrying a body. Following fragments must match identifiers, conversations, channel, reply expectation and count, and their sizes must sum exactly. Header bounds precede body reads. Payload and auxiliary lengths are validated; unknown/compressed payload kinds fail explicitly. A callback invocation cannot be mistaken for an acknowledgement solely because its identifiers match.

Outgoing invocations archive project-owned selectors and arguments with Foundation secure coding. Replies preserve the identifier, advance the conversation and apply channel direction rules; overflow and unrepresentable channel negation fail. The parser leaves received archive contents opaque. Handling a DTX acknowledgement does not establish an accessibility semantic response or subscription cleanup.

Protocol facts were cross-checked against the existing [accessibility notes](ACCESSIBILITY-PROTOCOL.md), the pinned MIT [ipb protocol reference](https://github.com/ipbtools/ipb/blob/8c227a10710dad479852aa0203de729fed57471b/docs/protocol.md), and pinned AXe source reviewed in [AXE-PHYSICAL-REVIEW.md](AXE-PHYSICAL-REVIEW.md). This is project-owned interoperability code; neither reference executable is a runtime dependency. Installed Apple CoreDevice exports separately confirm service-name and feature-identifier socket methods and optional input fields. They do not establish that a particular service connection will succeed.

## Remaining integration

Opening the selected device's raw accessibility socket, serving version negotiation, enabling/disabling accessibility, request/callback routing, bounded data-only archive decoding, fresh application snapshots, selector guards and CLI/MCP routing still need direct implementation and hardware verification. Historical results below other documentation headings are acceptance targets, not verification of this codec or transport.

## Local validation

On 2026-11-13, `mise run test` passed 160 Swift test functions with zero errors/warnings on macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2. Seven new tests cover an independent byte fixture, outgoing subscription archives, fragment assembly/correlation, malformed header/payload/argument bounds, reply direction/overflow and opaque unknown archive class names. No phone request was sent by these tests. A successful build or codec test is not a live tree result.
