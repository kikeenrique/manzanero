# Screen recording

Recording writes a finite MP4 to a new host path. Simulator capture uses `simctl`. Physical capture defaults to `devicectl`, but that capability is rejected by the tested iPhone 13 mini; select the in-process CoreDevice route explicitly there.

```sh
manzanero record tmp/demo.mp4 5 h264 --simulator <UUID>
manzanero record tmp/phone.mp4 5 hevc --backend coredevice --device <hardware-UDID>
manzanero media-status --device <device>
```

## Requirements and destination rules

- Duration: finite `1...300` seconds.
- Output codec: `h264` (default) or `hevc`.
- Destination: new `.mp4`; its parent directory must already exist.
- Simulator: explicit UUID.
- Not an Apple TV: `record` and `frames` are refused there as `unsupported-operation` before any stream starts, because its stream arrived blank ([Apple TV](other-families.md#a-physical-apple-tv)). `screenshot` works.
- Native physical route: explicit hardware UDID, pairing/Developer Mode, and an awake display. (It used to be gated on macOS 26; the whole tool now requires macOS 26.6.)

Existing destinations are refused, including a path created while capture runs. Display preflight distinguishes off, unknown power and invalid geometry. Wake/unlock guidance is not proof that the host can detect current UI unlock.

MCP `record_screen` uses `platform`, `device`, `path`, `seconds`, optional `codec`, `recording_backend: coredevice` on a physical device, and optional `display` on a simulator ([iPhone Duo](other-families.md#displays-iphone-duo)). It returns saved-path metadata, not inline video. There is no automatic fallback, audio capture or live-mirroring session.

## The macOS firewall can drop the video

Native recording receives the device's video as incoming UDP on the tunnel interface. If the macOS firewall is on and has no rule allowing the `manzanero` executable, those datagrams are dropped silently. The stream starts, cleanup is acknowledged, and the recording fails with `exceeded its twelve-second first-frame budget` and `packets=0`.

Firewall rules are per executable path. A source build (`.build/…/manzanero`), a build in another checkout, and an installed copy each need their own rule, and a rule for an earlier name or location does not carry over. An executable signed by an identified developer may be allowed automatically when the firewall's signed-software option is on; an ad-hoc signed build, such as a source build or the current beta archive, is not.

`manzanero doctor` reports this as a `Firewall` entry with status `off`, `allowed`, `blocked`, `no-rule` or `unknown`, and a recording that receives no packet adds the likely cause to its error. To fix it, allow incoming connections for the path `doctor` prints, under System Settings > Network > Firewall > Options, or as an administrator:

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path-from-doctor>
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp <path-from-doctor>
```

Manzanero only reads the firewall state. It never changes a rule and does not work around the firewall.

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

A native recording holds the per-device lease, so another `manzanero` process's input or native capture is refused while it runs ([ownership](native-input.md#ownership-across-processes)); within one process input is allowed alongside it. Xcode and other tools are not coordinated. Synchronous Apple calls have no independently enforced hard deadline.

## RTCP and keyframe limits

The media owner sends bounded compound Receiver Reports plus a random per-session CNAME to the validated owned peer. Reports carry loss/sequence, HEVC jitter and sender-report timing. A 100 ms heartbeat checks the negotiated interval; blocking main-actor calls can delay it.

`rtcp.receiverReportsSent` counts successful local UDP sends, not remote acknowledgements. `senderReportsObserved` counts validated sender reports. Transient send failures drop a report; persistent failures stop capture.

`rtcp.negotiatedFeedback` is `enabled`, `disabled` or `unknown` from Apple's negotiated screen result after answer acceptance. Class/selector/return-ABI guards preserve unknown for unsupported contracts. It does not infer feedback from ordinary RTCP enablement, alter an offer or send feedback. Installed getter signatures are verified. Read live on the iPhone 13 mini on 2026-11-17, it was `disabled` twice with the stock offer, which does not ask for feedback, and `disabled` again in one recording whose offer did ask ([verification](verification.md#an-offer-that-asks-for-rtcp-feedback)). Even enabled would not establish PLI/FIR compatibility.

Keyframe requests over negotiated feedback are therefore not planned: that phone declines them. Recovery from loss, a crash or a disconnect is to be a restart of the stream, and is not built. Startup failures with zero packets on the test Mac were traced to the firewall (above); whether every earlier startup failure had that cause was not checked.

## Frames: repeated screenshots from one stream

`frames` opens the same owned native stream as `record --backend coredevice` and saves frames as JPEG files instead of a movie. The stream is negotiated once, so after the first frame each further one costs tens of milliseconds rather than a `devicectl` run. Physical devices only; on a simulator it is refused as `unsupported-operation`, and `screenshot` is the tool there.

```sh
manzanero frames tmp/shots --count 10 --device <UDID>
manzanero frames tmp/shots --seconds 5 --interval 500 --device <UDID>
```

- **Files.** `frame-0001.jpg`, `frame-0002.jpg`, … and `frames.json`, which lists each frame's `file`, `offsetMilliseconds` from the first frame, `width`, `height` and `bytes`, with `status` (`captured`, `interrupted`, `failed` or `cleanup-unconfirmed`), `stopReason`, `firstFrameDelayMilliseconds` and `lastFrame`. Stdout carries the same plus the stream's negotiated size, packet and access-unit counts, setup time and cleanup acknowledgements.
- **When it stops.** At `--count` frames (1...1000; default 10, or 1000 when only `--seconds` is given), `--seconds` after the first frame (0.5...300), or before a frame that would take the run past 1 GiB of JPEG, whichever comes first. The first frame must arrive within 12 seconds of the stream request.
- **Spacing.** Without `--interval` every decoded frame is saved, at most one per 33 ms (about 30 per second; the stream delivered one every 65 ms or so on the test phone). `--interval <ms>` (0...60000) saves the first frame that arrives at or after each multiple of the interval from the first frame, so one late delivery does not delay the rest.
- **Directory.** Created if missing; its parent must exist. A non-empty directory is refused unless `--overwrite`, which replaces same-named frames and `frames.json` and leaves other files alone.
- **Image.** Every access unit is decoded with VideoToolbox to keep reference pictures; only a frame that will be saved is encoded, at JPEG quality 0.85. The stream pads the screen to its negotiated size on the right and bottom (1125×2436 to 1136×2448 on the iPhone 13 mini), so frames are cropped to the display's bounds, the size `screenshot` saves; a display larger than the stream would keep the whole picture. Frames are in the display's native (portrait) orientation; rotated displays are untested.
- **Interruption.** SIGINT or SIGTERM (CLI, exit 130/143) and MCP cancellation stop the stream with the same owned cleanup as a recording, keep the frames already written, mark `frames.json` `interrupted`, and print a one-line summary with the frame count and cleanup on stderr. MCP `capture_frames` returns the last frame inline, shaped by the usual `image_*` options.
- **Ownership.** It takes the device lease and the in-process stream reservation that native recording uses, so a second process's input or capture is refused while it runs, and a pending handoff pauses it. It sends no input.

While the stream runs, iOS shows its screen-sharing indicator in the status bar, which replaces the clock in later frames and lingered in a `screenshot` taken just after a run. The home indicator and rounded corners do not appear in the stream.

`frames` with no interval took 2.4 s for 10 frames on the iPhone 13 mini against about 0.7 s for one `screenshot`, but 1.8 s for a single frame: the tunnel, identity and display queries (about 0.75 s) and the stream start (about 0.5 s to the first frame) come first. From about three images on, `frames` is the quicker way.

### The bridge's decoded-JPEG mode is refused

The bridge used to have a mode in which Apple's own decoder handed over frames, encoded to JPEG in the bridge. `frames` was first written against it. It refused before any stream started with `Installed AVCStreamOutput denies access to this process; no stream started`: `-[AVCStreamOutput validateAccess]` admits only the process names listed in AVConference's `AVCStreamOutputAccess.plist` (FaceTime, ContinuityCaptureAgent, test runners and a few others), and `manzanero` is not one of them. Getting past it would mean changing a default, renaming the process or patching the framework, which this project does not do. `frames` therefore decodes the standard-RTP stream itself, as recording does. The mode was removed on 2026-11-17 by the owner's decision, with its `native-recording-jpeg` entry in `doctor` and the `test:media-frames` task that exercised it; git history has it.

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

The older AVConference-output experiment was denied by Apple's `AVCStreamOutput` access validator and has been removed ([above](#the-bridges-decoded-jpeg-mode-is-refused)). No override, process spoofing or framework hook is used. The old ipb video helper/ADV1 pipe has been removed.

## Verified scope

On iPhone 13 mini, short CLI H.264/MCP HEVC recordings and one 300-second CLI HEVC capture finalized with required cleanup. The five-minute movie had 5966 source frames; it is stationary-screen evidence, not inspection of every frame or motion quality.

`frames` ran on the same phone in portrait: counts, an interval run, SIGINT, SIGTERM and MCP cancellation, each with owned cleanup acknowledged ([verification](verification.md#frames-on-the-phone)).

A twenty-second real MCP movie captured AX inspection and an effective Settings → Home transition. Request cancellation and EOF/SIGINT/SIGTERM cleanup/reuse each passed scoped live checks. Earlier first-frame timeouts, zero-packet attempts, denied AVC output access and historical persistent sharing indicators remain important negative evidence.

See [verification](verification.md) for dates, environment and limits. Other Apple families, rotations, crash/disconnect recovery and general unattended reliability remain unverified.
