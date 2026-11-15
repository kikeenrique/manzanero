# Screen recording

Recording writes a finite MP4 to a new host path. Simulator capture uses `simctl`. Physical capture defaults to `devicectl`, but that capability is rejected by the tested iPhone 13 mini; select the in-process CoreDevice route explicitly there.

```sh
manzanero simulator <UUID> record tmp/demo.mp4 5 h264
manzanero --recording-backend coredevice physical <hardware-UDID> record tmp/phone.mp4 5 hevc
manzanero physical <device> media-status
```

## Requirements and destination rules

- Duration: finite `1...300` seconds.
- Output codec: `h264` (default) or `hevc`.
- Destination: new `.mp4`; its parent directory must already exist.
- Simulator: explicit UUID.
- Native physical route: macOS 26+, explicit hardware UDID, pairing/Developer Mode, and an awake display.

Existing destinations are refused, including a path created while capture runs. Display preflight distinguishes off, unknown power and invalid geometry. Wake/unlock guidance is not proof that the host can detect current UI unlock.

MCP `record_screen` uses `platform: physical`, `recording_backend: coredevice`, `device`, `path`, `seconds` and optional `codec`. It returns saved-path metadata, not inline video. There is no automatic fallback, audio capture or live-mirroring session.

## Native physical pipeline

The operation retains an Apple tunnel assertion and an in-process reservation for the resolved device UUID. It refuses pre-existing media sessions, negotiates an owned standard-RTP stream and validates endpoints, payload and cipher settings.

Project code reconstructs single-layer, non-interleaved HEVC NAL/aggregation/fragmentation packets without DONL. Pictures are bounded to 8 MiB/256 NAL units; VPS/SPS/PPS are at most 65535 bytes each. Gaps or incomplete pictures discard dependent output until a random-access picture. There is no reordering/jitter buffer, multilayer handling or H.264 input decoder.

VideoToolbox decodes the stream. During its synchronous callback, CoreImage copies BGRA pixels into owned buffers, consumed into Apple's sendable read-only pixel-buffer type before crossing to the encoder actor. AVFoundation encodes the requested H.264/HEVC output. Movies do not use a JPEG roundtrip; diagnostic frame probes still save JPEGs.

A twelve-second first-frame budget precedes the requested capture interval. Pixel delivery is capped at 30 fps while reference pictures still decode. Limits include 8192 pixels per axis, 20 megapixels, 10000 delivered frames and a 1 GiB transport budget. Encoding awaits each append rather than collecting the whole movie.

The tested stream negotiates 1136×2448 but codes 1136×2464; bounded upward padding to the next 32-pixel boundary is accepted. Changed parameter sets, dimensions or non-increasing presentation timestamps fail capture. The output timeline is host pixel delivery, not original device presentation timing. The last image is held through the requested end.

## Ownership, cleanup and publication

Approximately once per second and at capture end, status must identify exactly one running session matching the owned start identifier. Missing or ambiguous ownership fails capture. No stop-all fallback is sent.

Publication requires VideoToolbox invalidation to return, acknowledged owned stream stop, fresh owned-stream absence, acknowledged tunnel release, and a staged movie with finite positive duration, actual codec and a decodable frame. The staged movie is then moved from private `tmp/recording-<UUID>/` storage to the new destination.

Receipts report:

- `backend: coredevice-videotoolbox`, `sourceFrames`, `timeline: host-pixel-delivery`, `audio: false`;
- actual artifact duration, decoded dimensions and codec;
- separate stream/tunnel cleanup fields;
- RTCP report counters and negotiated-feedback observation.

`deviceStopConfirmed` means owned stop acknowledgement plus fresh server absence; it does not prove destruction of every native resource. Cancellation/failure publishes no successful movie receipt. Failed/staged artifacts may remain privately for investigation.

Independent processes/controllers are uncoordinated. Synchronous Apple calls have no independently enforced hard deadline.

## RTCP and keyframe limits

The media owner sends bounded compound Receiver Reports plus a random per-session CNAME to the validated owned peer. Reports carry loss/sequence, HEVC jitter and sender-report timing. A 100 ms heartbeat checks the negotiated interval; blocking main-actor calls can delay it.

`rtcp.receiverReportsSent` counts successful local UDP sends, not remote acknowledgements. `senderReportsObserved` counts validated sender reports. Transient send failures drop a report; persistent failures stop capture.

`rtcp.negotiatedFeedback` is `enabled`, `disabled` or `unknown` from Apple's negotiated screen result after answer acceptance. Class/selector/return-ABI guards preserve unknown for unsupported contracts. It does not infer feedback from ordinary RTCP enablement, alter an offer or send feedback. Installed getter signatures are verified; the live value remains unverified because the phone was off during the attempted probe. Even enabled would not establish PLI/FIR compatibility.

Keyframe requests, reliable startup and loss recovery remain unfinished.

## Other capture paths and probes

Simulator capture waits up to 30 seconds for the first-frame stderr marker, starts its duration there, sends SIGINT to its owned recorder and waits up to 30 seconds for finalization. An unresponsive child is killed/reaped. Parent termination can bypass cleanup.

The default physical `devicectl` path advertises finite capture in Xcode help but returned capability error 1001 on the tested phone.

| Diagnostic task | Scope |
| --- | --- |
| `test:media-status <UDID>` / `test:mcp-media <UDID>` | Read support flags/status without starting or stopping a stream |
| `test:media-packets <UDID> --decode` | Two-second packet/HEVC frame probe with owned cleanup |
| `test:mcp-recording <UDID>` | Real MCP short movie, artifact/frame inspection and subsequent screenshot |
| `test:mcp-recording-interaction <UDID>` | Twenty-second capture with AX read and Home control |
| `test:mcp-cancel-recording <UDID>` | Cancel active capture, check cleanup and immediately record again |
| `test:mcp-shutdown-recording <UDID> <EOF|SIGINT|SIGTERM>` | Stop the owned server during capture and record from a separate process afterward |

Run these via `mise run`. They are opt-in; input-bearing tasks change the phone.

The older `test:media-frames` AVConference-output experiment is denied by Apple's `AVCStreamOutput` access validator. No override, process spoofing or framework hook is used. The old ipb video helper/ADV1 pipe has been removed.

## Verified scope

On iPhone 13 mini, short CLI H.264/MCP HEVC recordings and one 300-second CLI HEVC capture finalized with required cleanup. The five-minute movie had 5966 source frames; it is stationary-screen evidence, not inspection of every frame or motion quality.

A twenty-second real MCP movie captured AX inspection and an effective Settings → Home transition. Request cancellation and EOF/SIGINT/SIGTERM cleanup/reuse each passed scoped live checks. Earlier first-frame timeouts, zero-packet attempts, denied AVC output access and historical persistent sharing indicators remain important negative evidence.

See [verification](verification.md) for dates, environment and limits. Other Apple families, rotations, crash/disconnect recovery and general unattended reliability remain unverified.
