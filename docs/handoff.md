# Human handoff

Handoff asks a person to perform a step on the selected device. It does not detect prompts, perform the step or verify its effect.

```sh
manzanero handoff 'Complete Face ID on the phone' --device <hardware-UDID>
manzanero handoff 'Finish the permission step' 120 --simulator <UUID>
manzanero handoff 'Enable Developer Mode and restart' --device <hardware-UDID> --dry-run
```

Use a hardware UDID for physical devices or UUID for simulators. Names, `booted` and physical CoreDevice UUID aliases are rejected. Format validation does not establish device presence; discover the target first.

Messages accept at most 2048 UTF-8 bytes and exclude terminal controls except tab/newline. Never put a passcode, password or other credential in the message.

## Terminal flow

The CLI requires an interactive terminal, prints the request to stderr and rings a terminal bell. Perform the device step, then enter:

| Response | Outcome |
| --- | --- |
| `done` | Acknowledged |
| `decline` | Declined |
| `cancel` or EOF | Cancelled |
| Timeout | Timed out |

Blank/other responses do not acknowledge completion. Default timeout is 300 seconds, configurable `1...3600`. Oversized input is drained through its newline with bounded retained data, then rejected.

Stdout returns JSON with status, mechanism, `humanAcknowledged` and `verified: false`. Only acknowledged exits 0; unsuccessful outcomes exit 1. Inspect fresh device state afterward.

Noninteractive stdin is refused. This coordinates workflow; it is not proof of human identity or a security approval boundary.

## MCP flow

`request_handoff` takes `platform`, `device` and `message`. A host advertising form elicitation receives one required Boolean completion checkbox, default false. Only acceptance with exactly `completed: true` acknowledges completion.

Decline, cancel, missing/false/wrong-type content or unexpected fields do not become success. Hosts with no form support receive an actionable error. The form never asks for credentials.

There is no server-enforced MCP handoff deadline. A response or server shutdown ends the request; native notifications, mirror banners and automatic prompt detection are absent.

## Process-local pause

While a handoff is pending, the shared service rejects mutations targeting that device. Observations remain available and other explicit devices can still be used. Duplicate handoff is refused.

Mutations during pending handoff require explicit hardware UDIDs/simulator UUIDs rather than aliases, preventing an alias from bypassing the pause. The pause ends when the response completes or fails; callers must respect declined/cancelled outcomes.

This does not coordinate a second CLI/server process, manual device use or arbitrary build scripts. Host approvals are separate.

## Evidence

Synthetic terminal/MCP exchanges verify completion handling and mutation pause; a synthetic `request_handoff` also ran in a live MCP session against a simulator. No actual biometric, passcode, purchase or permission action is claimed. A live test with a real prompt waits for the owner to say when ([roadmap](roadmap.md#waiting-for-the-owner)). See [verification](verification.md) for project evidence.
