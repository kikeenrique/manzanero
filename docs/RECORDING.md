# Screen recording

**Current availability:** the `coredevice` recording option below is disabled because it launches a non-Apple ipb executable. Its direct Apple API replacement is pending. Simulator simctl recording remains available; physical devicectl recording retains its documented capability failure. Native recording implementation details and evidence below are historical migration references.

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
