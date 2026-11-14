# Screen recording

**Current availability:** explicit `coredevice` physical recording uses in-process Apple negotiation, HEVC RTP/VideoToolbox decoding and AVFoundation encoding. Two-second CLI H.264/MCP HEVC and 35-second CLI HEVC movies have iPhone 13 mini verification, including owned cleanup. Native receiver reports are implemented. Startup remains intermittent; keyframe/crash recovery and captures beyond verified durations remain incomplete or unverified. Simulator recording remains available; default physical devicectl recording retains its documented capability failure.

## Native physical movies

```sh
mise run cli --recording-backend coredevice physical <hardware-UDID> record tmp/phone.mp4 2 h264
mise run cli --recording-backend coredevice physical <hardware-UDID> record tmp/phone-hevc.mp4 2 hevc
mise run test:mcp-recording <hardware-UDID>
```

MCP `record_screen` uses the same operation with `platform: physical`, `recording_backend: coredevice`, hardware UDID, new `.mp4` path, `seconds` and optional `codec`. macOS 26+ is required. No device helper is launched and no fallback occurs. The selected device must be paired, connected, in Developer Mode and awake. Current tunnel assertions require an explicit hardware UDID.

The controller reserves the resolved device UUID in this process, retains a tunnel assertion and refuses a pre-existing media session. A twelve-second first-frame budget precedes the requested 1...300-second interval. VideoToolbox decodes reference pictures even when pixel delivery is capped at 30 fps. During the synchronous decode callback, CoreImage copies BGRA pixels into an owned mutable buffer, which is consumed into Apple's sendable `CVReadOnlyPixelBuffer` before crossing to the encoder actor. No JPEG conversion is used for movies; the diagnostic frame probe retains its JPEG output. Limits include 8192 pixels per axis, 20 megapixels, 10000 encoded frames and a 1 GiB transport budget. Encoding awaits each append instead of collecting a whole recording's frames. The timeline measures host pixel delivery and holds the final image through the requested end. There is no audio.

Read-only status checks approximately once per second and at capture end require exactly one running session matching the owned start identifier. Missing, malformed or ambiguous ownership fails capture. Publication requires returned VideoToolbox invalidation, acknowledged owned stream stop, fresh absence status, acknowledged tunnel release and an independently decodable staged movie. Existing destinations are refused, including files created during capture. Private staging directories remain under `tmp/recording-<UUID>/`. Failure/cancellation does not publish a success receipt.

`mise run test:mcp-cancel-recording <hardware-UDID>` starts a 30-second native capture, waits for its first decoded frame and confirms an active session through an interleaved MCP status request, then cancels it. On the designated iPhone 13 mini, owned stop/absence/tunnel-release acknowledgement was observed about 0.107 seconds after cancellation. Fresh status found zero sessions, no cancelled destination was published, and a new two-second HEVC movie finalized and decoded successfully before clean MCP EOF exit.

`mise run test:mcp-shutdown-recording <hardware-UDID> <EOF|SIGINT|SIGTERM>` interrupts the owned MCP process after the same active-frame/status checks. Each mode passed once on this phone: expected exits 0/130/143, acknowledged owned cleanup, zero sessions from a fresh process, no interrupted movie or success output, and a successful two-second recording from that separate process. Observed shutdown intervals were about 0.090/0.148/0.100 seconds, not general latency bounds. Crashes, disconnection and stalled synchronous calls remain unverified.

Receipts use `backend: coredevice-videotoolbox`, actual artifact duration/dimensions/codec, `sourceFrames`, `timeline: host-pixel-delivery`, `audio: false` and explicit cleanup results. `deviceStopConfirmed` refers to the owned stop acknowledgement plus fresh server absence, not every native resource's destruction. Independent controllers are not coordinated and synchronous framework calls lack hard deadlines.

With the pixel pipeline, one 300-second CLI HEVC capture on iPhone 13 mini finalized with 5966 source frames, 295 receiver-report sends, 300 validated sender reports, a decodable 1136×2464 movie and required cleanup acknowledgements. This verifies one stationary-screen capture at the maximum accepted duration, not motion quality, every frame, sustained frame rate or general reliability.

Native packet sessions now send compound RTCP Receiver Reports plus one random, per-session CNAME. The receiver SSRC must match Apple's offered local SSRC, the peer SSRC must be distinct and nonzero, and the reply must confirm the bound receiver port, RTCP enablement and a finite 0.2...10-second report interval. Those identities stay in memory and are not serialized. Reports carry sequence/loss, 90-kHz HEVC interarrival jitter and last-sender-report/delay fields. A main-actor heartbeat checks every 100 ms and sends at the negotiated interval, including while movie encoding awaits. It is cancelled when the media owner closes. Main-actor blocking calls can still delay this schedule.

The native send boundary accepts only a bounded owned RR + CNAME compound packet for the already connected peer. It checks sources, report-block target, lengths and CNAME padding. Transient nonblocking send failures drop that report; persistent send failures fail capture. `rtcp.receiverReportsSent` counts successful local UDP sends, not remote acknowledgements; `senderReportsObserved` counts validated reports from the negotiated sender. A 35-second HEVC CLI check produced 559 source frames and 35 report sends, with decoded 1136×2464 output and acknowledged cleanup. A subsequent two-second MCP movie observed two sender reports and sent two receiver reports. This is scoped liveness evidence, not proof that reports caused it or that every movie frame was inspected. Keyframe feedback requests are not implemented yet.

An initial CLI attempt timed out waiting for its first frame with an active stream and acknowledged cleanup. A later two-second CLI H.264 recording during one native Home press produced 39 source frames; real MCP HEVC recording without UI input produced 28. Both finalized as decodable 1136×2464 movies with two-second duration. These scoped checks do not establish reliable startup, sustained frame rate, long captures, RTCP recovery or other device families. Sections explicitly labeled historical below describe retired helper behavior, not current setup.

## Native media control inspection

```sh
mise run cli physical <device> media-status
mise run test:media-status <hardware-UDID>
mise run test:mcp-media <hardware-UDID>
```

MCP `inspect_device` accepts `platform: physical`, `query: media-status`. This read-only operation resolves fresh paired/connected physical identity and Developer Mode, opens Apple's media feature control socket in process, then requests only `mediastreamgetsupportinfo` and `mediastreamstatus`. It returns raw support flags, AVC version, running state, duration and session count. It does not generate an offer, create a media UDP socket, install a decoder hook, start/stop any stream or export session identities/keys. No helper or new dependency is used.

Socket reply waits have a 15-second limit; each media reply wait has at most eight seconds within a shared 20-second control budget, with cancellation polling. Those limits cover waits, not an independently enforced bound on every synchronous Apple framework call. Close requests native RemoteXPC and host XPC cancellation; independent remote teardown is not verified. The parser checks typed scalar fields and an inventory cap of 128 sessions after Apple's wire decode; it does not audit framework allocations or turn support flags into verified recording availability.

On 2026-11-14, the opt-in integration check, actual CLI and real MCP stdio read the designated iPhone 13 mini successfully: flags 972, AVC `2260.15.1`, `running: false`, zero sessions and zero duration. MCP EOF shutdown passed. This is current server-status evidence, not proof of how historical sessions ended. Recording/frame delivery remains unfinished. The reference helper's process-wide decoder globals/hook and process-exit watchdog cannot be transplanted as an owned reusable MCP session without additional lifecycle work.

## Experimental native frame probe

`mise run test:media-frames <hardware-UDID>` explicitly tests one in-process media session. It is an integration probe, not the CLI/MCP recording backend. It intends to save a first JPEG and observe frames for two seconds under a private `tmp/media-frames-<UUID>/` directory, then stop only the identifier returned for its start request. It refuses a baseline with active media sessions, checks negotiated IPv6 endpoints against the selected tunnel and bound receiver, and never sends stop-all. On an ambiguous start reply without an owned identifier, remote cleanup remains unknown.

The current host denies access to Apple's `AVCStreamOutput` for our process. The probe detects that with Apple's own access validator before opening a media channel or starting a stream, and exits nonzero. It does not change access-control defaults, process identity or framework methods. A different frame-delivery API is still needed; no frames or movie have been verified through this replacement.

Earlier probes reached a successful start reply but captured zero frames. Session-specific stop was acknowledged and fresh status reported zero sessions; tunnel assertion release was acknowledged. One probe also configured the in-process decoder before output access was denied. Local cleanup fields describe stop/release requests, not independently verified decoder destruction. Synchronous private calls have no independent hard deadline. Cancellation, crash recovery, overlapping controllers and other Apple families remain unverified. See the dated [verification record](VERIFICATION.md).

## Experimental standard-RTP transport

`mise run test:media-packets <hardware-UDID>` tests another transport path toward frame decoding. Project code uses Apple's media negotiator and the paired device tunnel, with the standard-RTP options described in the [AXe reference review](AXE-PHYSICAL-REVIEW.md). It does not instantiate `AVCStreamOutput`, invoke another device binary or replace framework methods. Apple's installed settings factory resolves the concrete CoreDevice screen-sharing class before an offer is generated. Negotiator mode and the settings' operating mode are different enums.

Before consuming packets, the probe requires the selected tunnel endpoints, RTP transport, zero SRTP/SRTCP cipher selectors, typed dimensions up to 8192 per axis/20 megapixels, frame rate 1...240 and payload type 0...127. Each nonblocking read borrows at most 65535 bytes. The probe observes two seconds after its first packet, capped at 10000 datagrams/32 MiB, and retains only counts and whitelisted negotiated metadata. It inherits the owned receiver-report lifecycle and does not export raw packets, SSRCs, negotiation blobs or keys.

On the designated phone, one early probe received 235 datagrams (233 with RTP header prefixes and two with RTCP header prefixes), negotiated 1136×2448 at 60 fps/payload 100, and acknowledged owned cleanup. Earlier probes received no packets within six seconds, so reliable startup is unresolved. Header classification alone is not codec/frame evidence. HEVC decoding, movie integration and receiver reports have since been verified in the scoped checks described here.

## Experimental HEVC frame decoding

```sh
mise run test:media-packets <hardware-UDID> --decode
mise run test:media-packets <hardware-UDID> --home --decode
```

`--decode` reconstructs HEVC access units and decodes them with Apple's public VideoToolbox APIs. It saves the first JPEG privately alongside the probe receipt. Optional `--home` sends one native Home button press after stream start and changes the foreground. This remains a frame-level probe; use the native movie route above for CLI/MCP recording.

The parser checks RTP CSRC/extension/padding bounds and the negotiated payload number. HEVC assembly supports single-layer non-interleaved single NAL, aggregation and fragmentation packets without DONL fields. It bounds each picture to 8 MiB/256 NAL units and parameter sets to 65535 bytes each. Gaps/incomplete pictures discard dependent output until a new random-access picture; duplicates/reordered packets are ignored and source changes fail. It does not implement a reordering/jitter buffer, interleaving, multiple layers or H.264 decoding. The parser does not infer a codec from the dynamic payload number: VideoToolbox must accept the reconstructed parameter sets and samples.

VideoToolbox creates the format from VPS/SPS/PPS and decodes with async and temporal-processing flags clear. Apple's documented contract calls the output handler before decode returns; synchronous calls still lack an independent hard deadline. JPEG output is capped at 8 MiB and geometry at 8192 per axis/20 megapixels. The tested stream negotiates 1136×2448 but codes 1136×2464; the decoder permits bounded upward padding to the next 32-pixel boundary and preserves those actual pixels. Changed parameter sets or non-increasing presentation timestamps fail capture. Close invalidates the owned VideoToolbox session; a returned invalidation call is not independent resource-destruction proof.

On the iPhone 13 mini, the input-plus-stream check decoded 71 pictures in the two-second collection interval. A subsequent check with no UI input decoded 65. Both first JPEGs decoded with ImageIO at 1136×2464; independent inspection of the first input-check JPEG showed the Home screen, matching a later Apple screenshot. The no-input probe returned from VideoToolbox invalidation and acknowledged owned stream stop, zero sessions and tunnel assertion release. Its top-level `decodedFrames` counts VideoToolbox output; the nested bridge cleanup counters describe the unused AVConference decoder. These checks establish scoped live frame delivery, not an MP4, sustained 60-fps output, loss-free behavior or reliable unattended testing.

## Historical recording contract

```sh
appledevicescmd simulator <UUID> record tmp/demo.mp4 5
appledevicescmd simulator <UUID> record 'tmp/My Demo.mp4' 5 hevc
appledevicescmd physical <device> record tmp/phone.mp4 5
appledevicescmd --dry-run physical <device> record tmp/phone.mp4 5
mise run coredevice:video-build
mise run cli --recording-backend coredevice physical <UDID> record tmp/native-phone.mp4 5 hevc
```

Duration must be finite and between 1 and 300 seconds. Codec defaults to `h264`; `hevc` is also supported by the wrapped tools. The destination must end in `.mp4`, its parent must exist, and existing destinations are refused. Simulator recording requires an explicit UUID. Only the default display is selected; there is no audio option or live-mirroring session.

## Historical helper backends and completion

Simulator capture uses `simctl io recordVideo`. The controller waits up to 30 seconds for the documented `Recording started` message on stderr, including messages split across writes. Duration starts when that first-frame message is observed. It then sends SIGINT to its owned recorder and waits up to 30 seconds for encoding/finalization. Startup/early-exit/finalization failures return errors; an unresponsive owned child is killed and reaped. Task cancellation during the monitored interval requests the same cleanup. Killing the parent process can bypass cleanup.

Physical capture defaults to Xcode's `devicectl device capture screen-record --duration`, with a command timeout equal to the rounded duration plus 60 seconds. It does not require the Rust bridge. Installed Xcode 27.2 advertises this interface, but the selected iPhone 13 mini rejects the Screen Recording capability with error 1001 despite enabled Developer Mode and available developer services.

Select `--recording-backend coredevice` explicitly to use the optional [pinned ipb helper](DEPENDENCIES.md#native-video-helper), built by `mise run coredevice:video-build`, on PATH as `appledevices-video`. This path requires macOS 26+. It resolves the requested hardware UDID/CoreDevice UUID afresh, requires a connected IPv6 tunnel and exactly one matching active host utun /64, negotiates AVConference video, and receives decoded JPEG frames. Swift Subprocess provides streaming stdout, bounded stderr and cancellation/child teardown; AVFoundation writes H.264 or HEVC MP4. There is no automatic fallback or new third-party encoding package.

The helper emits `ADV1`, a big-endian UInt32 JPEG length, a big-endian UInt64 elapsed nanoseconds, and JPEG bytes. The first emitted JPEG is time zero; later timestamps must strictly increase and precede the requested end. The timeline measures host JPEG emission after decoding, not the original device presentation timestamp. The helper caps delivery at 30 fps, skips sampled-hash duplicates, and drops queued frames under backpressure. The last image is held through the requested duration for static screens. Frame reordering is disabled for seeking with irregular timestamps. Odd dimensions are padded to even dimensions; changing dimensions fail the recording. Limits are 8 MiB/JPEG, 20 megapixels, 8192 pixels per axis, 10,000 frames, and 1 GiB aggregate helper stdout.

Successful local decoder shutdown and helper exit do **not** confirm device-side media teardown. The purple screen-sharing indicator persisted in immediate and later screenshots during verification. Native receipts explicitly include `cleanup.helperExited: true`, `cleanup.deviceStopConfirmed: false`, and a warning. The helper does not issue a stop-all request. Session-specific cleanup, SIGINT/crash recovery, long captures, orientation changes, audio, and other device families remain unfinished or unverified.

The shared service now checks [readiness](READINESS.md) first. Explicitly disabled Developer Mode returns preparation guidance before capture is dispatched. A missing capability while developer support is unavailable must not be treated as proof of permanent device incompatibility.

All paths record to a unique `tmp/recording-<UUID>/capture.mp4`. AVFoundation loads its finite positive duration, reads the actual video codec FourCC, and decodes a video frame near time zero. Only then does the CLI move the movie to the requested destination, refusing an existing file even if it appeared while capture ran. Available failed/staged artifacts remain under `tmp/` for investigation; encoder cancellation may remove an unfinished movie. This does not validate every video frame, exact requested duration, audio, or app behavior.

Success is one JSON object containing `status: recorded`, backend, output path, requested duration/codec, and an `artifact` with actual duration, decoded frame dimensions, and `frameDecoded: true`. Encoder progress goes to stderr. A nonzero exit does not publish a successful receipt or replace the destination.

The shared operation is exposed as MCP `record_screen`, with optional physical `recording_backend: coredevice`; it returns metadata and a saved path, not inline video. Native capture permits interleaved service requests and rejects another native recording for the same resolved CoreDevice UUID in this process. Independent CLI processes and other controllers are not coordinated. Avoid simultaneous idevice HID input: that backend uses a stop-all media request.

## Historical helper evidence

Simulator H.264 and HEVC captures were finalized and decoded locally. On the selected USB iPhone 13 mini, the explicit native backend produced two-second H.264 (CLI) and HEVC (real MCP stdio) recordings with decodable 1136×2464 video. `mise run test:mcp-recording <UDID>` checks HEVC capture, duration, codec, cleanup disclosure, first-frame export and a subsequent screenshot. This does not verify moving app interaction during capture or device teardown. See [verification records](VERIFICATION.md) and [roadmap](ROADMAP.md).
