# Human handoff

Handoff asks a person to perform a step on the selected device. It does not detect prompts, perform the step or verify its effect.

```sh
manzanero handoff 'Unlock the phone' --until unlocked --device <hardware-UDID>      # ends by itself
manzanero handoff 'Complete Face ID on the phone' --device <hardware-UDID>
manzanero handoff 'Finish the permission step' 120 --simulator <UUID>
manzanero handoff 'Enable Developer Mode and restart' --device <hardware-UDID> --dry-run
```

Use a hardware UDID for physical devices or UUID for simulators. Names, `booted` and physical CoreDevice UUID aliases are rejected. Format validation does not establish device presence; discover the target first.

Messages accept at most 2048 UTF-8 bytes and exclude terminal controls except tab/newline. Never put a passcode, password or other credential in the message.

## Watching the device: `--until`

The better way to end a handoff is not to ask. With `--until` the handoff names what "finished" looks like on the device, watches for it, and ends by itself. The person only touches the device.

```sh
manzanero handoff 'Unlock the phone' --until unlocked --device <UDID>
manzanero handoff 'Pair the phone: click Pair, tap Trust' --until paired --device <UDID>
manzanero handoff 'Answer the notification prompt' 180 --until gone --label Allow --device <UDID>
manzanero handoff 'Sign in' --until visible --id home.title --simulator <UUID>
```

| `--until` | Finished when | Devices |
| --- | --- | --- |
| `unlocked` | The display is on and no passcode is required | Physical |
| `paired` | CoreDevice reports connected and paired | Physical |
| `visible`, `gone`, `enabled`, `disabled`, `value`, `focused` | [`wait`](direct-accessibility.md#bounded-wait-for-a-selector-condition)'s condition holds for the element `--id` or `--label` names (`--index` and `--value` as there) | Both |

How it runs:

- **It never watches forever.** The timeout is the same operand as before, 1...3600 seconds, default 300. At the deadline the result is `timedOut`, exit 1.
- **The condition is read first.** A step that is already done returns at once with `alreadyMet: true` and nobody is asked. The same happens when there was never anything to wait for, such as `gone` for a prompt that is not on screen; `alreadyMet` is how to tell.
- **It polls, read-only.** One look, then a 2-second pause, until the condition or the deadline. An element condition is a `wait` of 3 seconds each time. A look that fails (display asleep, device unreachable mid-pairing, a phone in landscape) counts as "not seen yet" and is reported in `observation.notObserved`; it is not an error, because the person may be in the middle of the step.
- **Waiting costs no model tokens.** The polling is inside this process; a caller makes one call and is blocked until it returns.
- **No terminal is needed**, so an agent's own shell can run it. At an interactive terminal the request is printed and `done`, `decline` and `cancel` are also taken between looks. From an MCP host there is no form: to refuse, cancel the call or let it time out.
- **The pause holds throughout.** Mutations for the device are refused while it is watched, and the watch ends with the call, including when it is cancelled.

The result has `status: observed`, `mechanism: device-observation`, `humanAcknowledged: false` and `verified: true`. `verified` is about the named condition only: a prompt that went away says nothing about which button was pressed. It also carries `until`, the last `observation`, `polls`, `elapsedSeconds`, `timeoutSeconds` and `alreadyMet`.

Use the forms below when a step leaves nothing on the device to see.

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

`request_handoff` takes `platform`, `device` and `message`. With `until` (and `by`, `text`, `index`, `value`, `timeout_seconds`) it [watches the device](#watching-the-device---until) and shows no form; prefer that whenever the step can be seen on the device. Without it, a host advertising form elicitation receives a form with no fields. The host's own Accept and Decline are the answer: accept is `acknowledged`, decline is `declined`, cancel is `cancelled`.

```text
Accept = step finished (any choice on the device). Decline = not done.
Step: Answer the notification prompt on the phone.
Device: physical <UDID>
```

It is three lines with no blank ones because Claude Code shows the first three lines of a form's message and folds the rest ("… (+4 more lines)"); a longer version of this text had its button meanings hidden that way. They come first so that a long step cannot push them out of sight, and a step given on several lines is joined into one.

The wording exists because two questions are on the table at once, with answers that look alike. The device asks its own, for example "Probe would like to send you notifications", answered Allow or Don't Allow. The form asks a different one, whether the person has finished, and its buttons are the host's, fixed as Accept and Decline. Read side by side, Accept looks like Allow and Decline like Don't Allow, so a person who refused the permission on the device would press Decline and report an unfinished step that was in fact finished. An earlier text, "Accept when it is done. Decline if you did not do it", under a step that named both device answers, was judged confusing by the owner for exactly this. So the form says what each of its buttons means, and that any choice made on the device counts as finished. Write the `message` as the step alone, an instruction, without yes/no wording of its own.

Two earlier forms had a field of their own, and both failed with a person in Claude Code, which draws a form inline at its prompt and adds Accept and Decline itself. A checkbox defaulting to false was submitted unticked four times by someone who had done the step. A required done/not-done choice was answered correctly once, but was shown as "not set — This field is required" beside the host's buttons, under a paragraph of explanation; the owner called it unacceptable and very confusing, because it asked the same thing twice. Keep the `message` to the step itself.

An accepted answer that carries fields is not what was asked and is reported as `notCompleted`. Hosts with no form support receive an actionable error. The form never asks for credentials. The tool result carries `formAnswer` (also as a last text line): the action the host returned, and the name and type of any field, with the value only for Booleans and numbers.

Accepting is one keypress, so it can be done by mistake. That is the same weight the result always had: `verified: false`, and the caller inspects the device afterwards.

There is no server-enforced MCP handoff deadline. A response or server shutdown ends the request; native notifications, mirror banners and automatic prompt detection are absent.

## Process-local pause

While a handoff is pending, the shared service rejects mutations targeting that device. Observations remain available and other explicit devices can still be used. Duplicate handoff is refused.

Mutations during pending handoff require explicit hardware UDIDs/simulator UUIDs rather than aliases, preventing an alias from bypassing the pause. The pause ends when the response completes or fails; callers must respect declined/cancelled outcomes.

This does not coordinate a second CLI/server process, manual device use or arbitrary build scripts. Host approvals are separate.

## Evidence

Synthetic terminal/MCP exchanges verify completion handling and mutation pause; a synthetic `request_handoff` also ran in a live MCP session against a simulator. On 2026-11-17 the terminal flow ran once with a person and a phone: the owner rotated an iPhone 13 mini and typed `done`, and a screenshot afterwards showed the rotation ([verification](verification.md#handoff-with-a-physical-step)). Later that day, with a passcode set, it ran once more around re-pairing the phone, where the person clicks Pair on the Mac, taps Trust and enters the passcode on the phone ([verification](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen)). An unlock with the passcode, `decline`, `cancel` and a timeout ran the same evening, and so did an app's permission prompt, raised by the probe app and decided by the owner ([verification](verification.md#handoff-with-an-app-permission-prompt)). No biometric or purchase action is claimed. From a real MCP host (Claude Code) the pause was seen on the phone: a tap sent while a `request_handoff` was pending was refused, and one sent after it returned was dispatched. The form was submitted four times with its checkbox unticked, because in that host it is drawn inline at the prompt and Enter submits it with the default; the server reported `notCompleted` each time, and the person had in fact done the step ([verification](verification.md#handoff-through-an-mcp-host-the-pause-and-a-form-the-person-never-saw)). With a required choice in place of the checkbox, one request was then acknowledged by the owner after they answered a notification prompt on the phone, which the probe confirmed. The form was simplified again after that run, to no fields, and the owner then answered it both ways from Claude Code: Accept after deciding a notification prompt, which the probe confirmed, and Decline. After the wording below was settled, the owner refused the permission on the phone and pressed Accept, and the step was reported finished with the probe reading `denied`. Cancel has not run from a host. See [verification](verification.md) for project evidence.
