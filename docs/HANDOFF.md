# Explicit human handoff

```sh
appledevicescmd physical <hardware-UDID> handoff 'Complete Face ID on the phone'
appledevicescmd simulator <UUID> handoff 'Finish the permission step' 120
appledevicescmd --dry-run physical <hardware-UDID> handoff 'Enable Developer Mode and restart'
```

This requests a person's action on the referenced device. It does not perform that action or detect a prompt automatically. Physical requests require the hardware UDID; simulator requests require a UUID. Device names, `booted`, and physical CoreDevice UUID aliases are rejected. The message is limited to 2048 UTF-8 bytes and excludes terminal control codes except tab/newline.

Identifier validation checks format, not device presence. Discover the target first. Handoff does not require Developer Mode and can request a preparation step while developer operations are blocked.

## CLI confirmation

The CLI requires an interactive terminal, prints the requested step to stderr, and emits a terminal bell. Complete the action on the device, then type `done`. `decline` and `cancel` return separate unsuccessful outcomes. Blank lines or other responses do not acknowledge completion. EOF cancels the request; the default terminal timeout is 300 seconds, configurable from 1 to 3600. Long input is consumed through its newline without retaining more than 64 bytes, then rejected as not completed.

Stdout contains JSON with `status`, `platform`, `device`, `mechanism`, `humanAcknowledged`, and `verified: false`. Only `acknowledged` exits 0; declined, cancelled, not-completed, and timed-out outcomes exit 1. A person's acknowledgement does not establish that Face ID, a permission, or another device operation succeeded. Inspect fresh device state afterward.

Noninteractive stdin is refused; a piped blank line cannot accidentally acknowledge a handoff. This is workflow coordination, not proof of human identity or a security approval boundary. An automated test or another local program can emulate terminal input.

## MCP confirmation

The `request_handoff` tool takes `platform`, `device`, and `message`. If the host advertises form elicitation, the server sends an `elicitation/create` form with one required boolean field: **I completed the requested step on the device**. It defaults to false. Only acceptance with exactly `completed: true` acknowledges the request. Decline, cancel, missing/false/wrong-type content, or unexpected fields cannot become completion.

The person performs the requested step on the device. The form never requests a passcode, password, or other credential. Callers should describe the needed action without putting secrets in the message. Hosts with no elicitation support, or URL-only support, receive an actionable tool error; no form is sent to them.

MCP host UI and notifications are host-dependent. This implementation does not provide a native Mac notification, mirror banner, or sound outside the CLI's terminal bell. Unlike the terminal path, the MCP wait currently has no server-enforced deadline. Host cancellation/disconnection handling is subject to the pinned SDK's pending-request behavior; cancellation is not guaranteed to release the wait immediately. A response or server shutdown ends the request. No persistent handoff state survives process exit.

## Pause coordination

While a handoff response is pending, the shared service rejects mutation operations targeting that device. Observation commands such as readiness, details, tree, screenshot, file/report reads, and logs remain available. Other explicit device identifiers can still be used. A duplicate handoff for the same target is rejected.

During a physical handoff, mutations must use hardware UDIDs; CoreDevice UUID/name aliases are rejected rather than risking bypass of the pause. Simulator `booted`/name aliases are also rejected during a pending simulator handoff. The pause ends when the response completes or fails, including a declined/cancelled response; callers must honor the unsuccessful result rather than assume completion.

Coordination is within one service process. It does not control a second CLI/server process, manual device interaction, arbitrary build scripts, or another controller. It is separate from host tool approvals.

## Evidence and remaining parity

The vendor's [human handoff]([private reference removed]) includes explicit agent requests, automatic prompt detection, and Mac alerts. This implementation covers explicit requests and response coordination. Automatic Face ID/passcode/permission detection, native background notifications, and mirror overlays remain absent.

Tests use synthetic terminal input and MCP client responses. No actual Face ID, passcode, purchase, or permission action is claimed. See [verification records](VERIFICATION.md).
