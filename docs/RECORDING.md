# Screen recording

**Current availability:** the `coredevice` recording option below is disabled because it launches a non-Apple ipb executable. Its direct Apple API replacement is pending. Simulator simctl recording remains available; physical devicectl recording retains its documented capability failure. Native recording implementation details and evidence below are historical migration references.

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

Before consuming packets, the probe requires the selected tunnel endpoints, RTP transport, zero SRTP/SRTCP cipher selectors, typed dimensions up to 8192 per axis/20 megapixels, frame rate 1...240 and payload type 0...127. Each nonblocking read borrows at most 65535 bytes. The probe observes two seconds after its first packet, capped at 10000 datagrams/32 MiB, and retains only counts and whitelisted negotiated metadata. It sends no receiver reports yet and does not export raw packets, SSRCs, negotiation blobs or keys.

On the designated phone, one probe received 235 datagrams (233 with RTP header prefixes and two with RTCP header prefixes), negotiated 1136×2448 at 60 fps/payload 100, and acknowledged its owned stop, empty-session status and tunnel assertion release. Earlier probes received no packets within six seconds, so reliable startup is unresolved. Header classification is not complete RTP validation, codec identification or decoded-frame evidence. VideoToolbox decoding, receiver-report handling, recording integration and longer-lived stream behavior remain unfinished.

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

## Backends and completion

Simulator capture uses `simctl io recordVideo`. The controller waits up to 30 seconds for the documented `Recording started` message on stderr, including messages split across writes. Duration starts when that first-frame message is observed. It then sends SIGINT to its owned recorder and waits up to 30 seconds for encoding/finalization. Startup/early-exit/finalization failures return errors; an unresponsive owned child is killed and reaped. Task cancellation during the monitored interval requests the same cleanup. Killing the parent process can bypass cleanup.

Physical capture defaults to Xcode's `devicectl device capture screen-record --duration`, with a command timeout equal to the rounded duration plus 60 seconds. It does not require the Rust bridge. Installed Xcode 27.2 advertises this interface, but the selected iPhone 13 mini rejects the Screen Recording capability with error 1001 despite enabled Developer Mode and available developer services.

Select `--recording-backend coredevice` explicitly to use the optional [pinned ipb helper](DEPENDENCIES.md#native-video-helper), built by `mise run coredevice:video-build`, on PATH as `appledevices-video`. This path requires macOS 26+. It resolves the requested hardware UDID/CoreDevice UUID afresh, requires a connected IPv6 tunnel and exactly one matching active host utun /64, negotiates AVConference video, and receives decoded JPEG frames. Swift Subprocess provides streaming stdout, bounded stderr and cancellation/child teardown; AVFoundation writes H.264 or HEVC MP4. There is no automatic fallback or new third-party encoding package.

The helper emits `ADV1`, a big-endian UInt32 JPEG length, a big-endian UInt64 elapsed nanoseconds, and JPEG bytes. The first emitted JPEG is time zero; later timestamps must strictly increase and precede the requested end. The timeline measures host JPEG emission after decoding, not the original device presentation timestamp. The helper caps delivery at 30 fps, skips sampled-hash duplicates, and drops queued frames under backpressure. The last image is held through the requested duration for static screens. Frame reordering is disabled for seeking with irregular timestamps. Odd dimensions are padded to even dimensions; changing dimensions fail the recording. Limits are 8 MiB/JPEG, 20 megapixels, 8192 pixels per axis, 10,000 frames, and 1 GiB aggregate helper stdout.

Successful local decoder shutdown and helper exit do **not** confirm device-side media teardown. The purple screen-sharing indicator persisted in immediate and later screenshots during verification. Native receipts explicitly include `cleanup.helperExited: true`, `cleanup.deviceStopConfirmed: false`, and a warning. The helper does not issue a stop-all request. Session-specific cleanup, SIGINT/crash recovery, long captures, orientation changes, audio, and other device families remain unfinished or unverified.

The shared service now checks [readiness](READINESS.md) first. Explicitly disabled Developer Mode returns preparation guidance before capture is dispatched. A missing capability while developer support is unavailable must not be treated as proof of permanent device incompatibility.

All paths record to a unique `tmp/recording-<UUID>/capture.mp4`. AVFoundation loads its finite positive duration, reads the actual video codec FourCC, and decodes a video frame near time zero. Only then does the CLI move the movie to the requested destination, refusing an existing file even if it appeared while capture ran. Available failed/staged artifacts remain under `tmp/` for investigation; encoder cancellation may remove an unfinished movie. This does not validate every video frame, exact requested duration, audio, or app behavior.

Success is one JSON object containing `status: recorded`, backend, output path, requested duration/codec, and an `artifact` with actual duration, decoded frame dimensions, and `frameDecoded: true`. Encoder progress goes to stderr. A nonzero exit does not publish a successful receipt or replace the destination.

The shared operation is exposed as MCP `record_screen`, with optional physical `recording_backend: coredevice`; it returns metadata and a saved path, not inline video. Native capture permits interleaved service requests and rejects another native recording for the same resolved CoreDevice UUID in this process. Independent CLI processes and other controllers are not coordinated. Avoid simultaneous idevice HID input: that backend uses a stop-all media request.

## Evidence

Simulator H.264 and HEVC captures were finalized and decoded locally. On the selected USB iPhone 13 mini, the explicit native backend produced two-second H.264 (CLI) and HEVC (real MCP stdio) recordings with decodable 1136×2464 video. `mise run test:mcp-recording <UDID>` checks HEVC capture, duration, codec, cleanup disclosure, first-frame export and a subsequent screenshot. This does not verify moving app interaction during capture or device teardown. See [verification records](VERIFICATION.md) and [roadmap](ROADMAP.md).
