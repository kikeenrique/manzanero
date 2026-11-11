# Screen recording

```sh
appledevicescmd simulator <UUID> record tmp/demo.mp4 5
appledevicescmd simulator <UUID> record 'tmp/My Demo.mp4' 5 hevc
appledevicescmd physical <device> record tmp/phone.mp4 5
appledevicescmd --dry-run physical <device> record tmp/phone.mp4 5
```

Duration must be finite and between 1 and 300 seconds. Codec defaults to `h264`; `hevc` is also supported by the wrapped tools. The destination must end in `.mp4`, its parent must exist, and existing destinations are refused. Simulator recording requires an explicit UUID. Only the default display is selected; there is no audio option or live-mirroring session.

## Backends and completion

Simulator capture uses `simctl io recordVideo`. The controller waits up to 30 seconds for the documented `Recording started` message on stderr, including messages split across writes. Duration starts when that first-frame message is observed. It then sends SIGINT to its owned recorder and waits up to 30 seconds for encoding/finalization. Startup/early-exit/finalization failures return errors; an unresponsive owned child is killed and reaped. Task cancellation during the monitored interval requests the same cleanup. Killing the parent process can bypass cleanup.

Physical capture uses Xcode's `devicectl device capture screen-record --duration`, with a command timeout equal to the rounded duration plus 60 seconds. It does not require the Rust bridge. Installed Xcode 27.2 advertises this interface, but device capability is separate: the initial phone tested rejected it as unsupported. That observation is not a recording test on the user's subsequently specified iPhone 13 mini. Physical recording remains unverified; there is no private-protocol fallback yet.

Both paths record to a unique `tmp/recording-<UUID>/capture.mp4`. AVFoundation loads its finite positive duration and decodes a video frame near time zero. Only then does the CLI move the movie to the requested destination, refusing an existing file even if it appeared while capture ran. Failed/staged artifacts remain under `tmp/` for investigation. This does not validate every video frame, exact requested duration, audio, or app behavior.

Success is one JSON object containing `status: recorded`, backend, output path, requested duration/codec, and an `artifact` with actual duration, decoded frame dimensions, and `frameDecoded: true`. Encoder progress goes to stderr. A nonzero exit does not publish a successful receipt or replace the destination.

The shared operation is exposed as MCP `record_screen`; it returns metadata and a saved path, not inline video. Recording occupies the shared command service during capture. After capture, asynchronous media inspection may allow another service request. Cross-process recording/input sessions are not coordinated; avoid simultaneous physical controllers.

## Evidence

Simulator H.264 and HEVC captures were finalized and decoded locally. The stdio MCP check additionally records a short H.264 movie and checks its metadata. Physical-device capture is not verified. See [verification records](VERIFICATION.md) and [roadmap](ROADMAP.md).
