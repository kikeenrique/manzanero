# Recording recovery: design

A design for what is item 22 of the [roadmap](roadmap.md#not-built), written on 2026-11-21 by laia-LLM at the human owner's request to work through the pending tasks that need no hardware. The choice it rests on (one movie with its gaps marked, rather than a file per segment) is the option laia-LLM recommended that day; the human owner can still change it.

**Built the same day for `record --backend coredevice` without `--audio`** (`RecordingRecovery`, wired into the loop `NativeRecording.record`), unit-tested against the scenarios below, then changed after a first live check and seen to recover across a pulled cable on the iPhone 13 mini ([below](#changed-after-that-check-waiting-for-the-device-and-keeping-what-was-captured)). Two departures from the design as first written: silence alone does not start a restart (see the table), and a recording with `--audio` or a `frames` capture fails on a loss as before, because the sound stream's restart needs a device with something audible to check and `frames` was left for later.

## The problem

`record --backend coredevice` and `frames` read one media session from start to end (`NativeRecording.record` in `NativeRecording.swift`, `NativeFrameCapture.execute`). Three things end a recording today, and each loses all of it:

| What happens | What the loop sees now | Result now |
| --- | --- | --- |
| The device ends the stream (a crash of its media service, another client taking the screen) | `requireActive()` fails at the next one-second look | The recording fails; the staged movie is cancelled |
| The socket or the tunnel fails (cable pulled, Wi-Fi lost, `remoted` reset) | `nextPacket()` throws, or `requireActive()` fails | The recording fails |
| Packets stop arriving, or arrive and no picture can be decoded from them (a loss with no random-access picture after it) | Nothing: the loop waits, and the last picture is held to the end | A movie whose end is one frozen picture, with no word of it in the result |

Asking the device for a new key frame is not a route: the phone negotiated RTCP feedback as `disabled` three times, once for an offer that asked for it ([recording](recording.md#rtcp-and-keyframe-limits)). A new session starts with a key frame, so the route is a restart of the session.

## What a restart is

After the first picture, a loss that can be recovered closes the session it belongs to and opens a new one on the same endpoint, while the movie stays open:

1. Close the media owner (`NativeMediaFrames.close()`), which sends the owned stop and checks the stream is gone, as at the end of a recording, and close the decoder.
2. If the tunnel assertion no longer holds, take a new one (`NativeTunnelAssertion`) from fresh device details; if that fails, stop recovering.
3. Open a new `NativeMediaFrames` with the same endpoint and offer, start it on the same display, and make a new `NativeHEVCDecoder` and `MediaHEVCAssembler`.
4. Wait for the new session's first picture within a budget of its own (below). Its pictures go on the movie's timeline at their host arrival time, as every picture does now (`timeline: host-pixel-delivery`), so the gap is the previous picture held, which is what the movie shows today for a still screen.

The requested duration counts wall-clock time from the first picture, gaps included, as now: a recording of 60 seconds is a movie of 60 seconds, with its gaps in it.

## When to restart

| Signal | Threshold | Why this value |
| --- | --- | --- |
| `requireActive()` fails | At once | The device has ended the stream |
| `nextPacket()` throws a transport error | At once | The socket is gone |
| No packet at all | Not a trigger as built | The design proposed 3 s, on the grounds that `frames` saved pictures from still screens. A restart a healthy quiet session did not need would cost a gap, so silence alone only holds the picture, as before; a session that has really ended is caught by the liveness check above. Measured on the iPhone 13 mini since: a still screen delivered a picture at least every 119 ms for a minute (below) |
| Packets arrive and no picture is decoded | 3 s without a picture, with a new video packet in the last second | The assembler discards everything after a gap until a random-access picture; three seconds without one is a picture that will not come. Only new video packets count (the negotiated payload type, a new sequence number and timestamp), and one must have come within the last second: a still Apple TV screen repeats one packet once a second after its pictures stop, which restarted a healthy session until this was changed ([record](verification.md#the-apple-tvs-still-screen-and-a-restart-it-did-not-need)) |

Never restarted, failed as now: cancellation (SIGINT, SIGTERM, MCP cancel), the 1 GiB transport budget, an encoder error, a change of picture size (a rotation, which the encoder refuses today), and anything before the first picture. A start that never delivers a picture is left alone on purpose: its diagnosis, the [firewall](recording.md#the-macos-firewall-can-drop-the-video) hint among them, depends on the zero-packet count it has now.

## Bounds

- **At most 3 restarts** in one recording. When they are used up, a lost stream fails the recording as now. A stall after the last restart is not a failure: the last picture is held to the end, as today, and the result says so.
- **10 s for a restart to deliver its first picture**, shorter than the first start's 12 s because the device has just answered. A restart that runs past it counts as used and the next one is tried, within the three.
- **The time left wins**: no restart begins with less than 2 s of the requested duration left; the last picture is held to the end instead.
- Each restart is one more media session the device must accept; the per-device lease and the process's reservation (`NativeRecordingSessions`) are held throughout, so no other capture or input from another process can slip in between sessions.

## The result

The receipt keeps `status: recorded` when the movie is published, and adds:

```json
"recovery": {
  "restarts": 1,
  "gaps": [{"atSeconds": 21.4, "seconds": 2.9, "reason": "stream-ended"}],
  "lastPictureHeldFrom": null
}
```

`reason` is `stream-ended`, `transport-failed`, `no-packets` or `no-pictures`. `lastPictureHeldFrom` is the second from which the picture was held to the end, when restarts ran out or the time left was too short. `cleanup` describes the last session; each earlier session's stop must have been acknowledged and its stream absent before the next was opened, or the recording fails then, with that session's cleanup in the error. `rtcp` counters add up across sessions; `negotiatedFeedback` is the last session's.

## Sound

With `--audio`, the sound stream belongs to the session and ends with it. A restart starts a new sound stream before the new video, as the first start does, and a new `NativeAudioTrack` anchored at its first packet's arrival on the movie's timeline; the gap is silence. If the new sound stream cannot start, the recording fails, because `--audio` has no silent fallback. This part needs a device with something audible to check, so it waits for the human owner's word on sound work.

## `frames`

`frames` gets the same restart and bounds. Its index already holds each frame's time from the first, so a gap shows as a jump in those times; the index gains the same `recovery` object.

## How it is tested before a device

As built, the decisions live in `RecordingRecovery`, which the loop feeds with packet, picture and failure times; `RecordingRecoveryTests` drives it through the scenarios below with made-up times. The loop's own wiring has a test stream since the evening of 2026-11-21: `NativeRecording.record` takes the media session, the decoder and the movie writer as protocols (`NativeRecordingSession`, which `NativeMediaFrames` implements; `NativeRecordingDecoder`; `NativeRecordingSink`), and every effect on the device and every reading of the clock through `NativeRecordingLink` (open a session, count the device's sessions, stop one by identifier, take a fresh link, release the assertion, the clock and the waits). `execute` fills it from the device; `NativeRecordingLoopTests` fills it with scripted sessions that send RTP packets of HEVC parameter sets and pictures, a decoder that makes a picture of every access unit and a clock that moves only when the stream or a wait moves it, so nothing sleeps. Its scenarios: a stream that ends after the first picture and comes back (one gap in one movie, every session closed before the next opens, reports added up); one that never comes back (three restarts, then the movie kept as partial); a stall with too little time left (the picture held, `lastPictureHeldFrom`); cancellation during a restart (the movie discarded); a change of size after a restart (the movie kept as partial); a loss before the first picture (failure, no restart); a lost link (two looks with no answer, the lost session stopped by its identifier, a fresh link, a new session); and a device that never answers again (thirty looks, then the movie kept as partial).

## First live check: a cable pulled

On the iPhone 13 mini on 2026-11-21 the cable was pulled 12 s into a 240-second recording. The loss was seen and a restart begun, but closing the lost session could not confirm its stop (the phone was unreachable), and the rule above ("each earlier session's stop must have been acknowledged and its stream absent before the next was opened, or the recording fails then") ended the recording, with its 101 pictures discarded ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)). So for a lost link the rule as written defeats recovery: the stop of a session on a device that cannot be reached can only be confirmed once it can be reached again.

## Changed after that check: waiting for the device, and keeping what was captured

At the human owner's choice of options A and B the same day:

- **A, a lost link.** When the lost session's stop cannot be confirmed, the restart asks the device every second, for up to 30 s (`RecordingRecovery.linkWaitNanoseconds`), how many media sessions it runs (`ADCInspectMedia`, read-only, over a fresh connection). With none, the new session is opened on freshly read details, tunnel assertion and endpoint, because the device's address can change when its cable comes back. With one still running, the tool stops its own lost stream by the identifier it was given at the start (`ADCStopVideoStreamByIdentifier`: the same `mediastreamstop` with `stopAll: false` that a normal stop sends, now over a new connection) and requires that no session remains. Anything else, a session it cannot identify as its own or a device that does not answer within 30 s, ends the recording, and nothing else is ever stopped.
- **B, a recording that cannot recover.** A failure after the first picture, other than an interrupt, keeps the movie: it ends just after its last picture, the result says `status: partial` with `stopReason`, and the command exits 1.

Seen on the iPhone 13 mini: with only the session count in place, a cable pull 62 s into a 240-second recording found the device answering again and still running one session (the lost one), opened nothing, and B kept the 62.6-second movie (`partial`, `recovery.gaps` with one `stream-ended`). The stop by identifier was added after that run; a further run with the cable pulled showed no loss at all (240 s, no restart), probably because the pull did not fall inside it or the stream moved to the network without ending. The next run, with the human owner pulling the cable about 30 s in and putting it back 10 to 20 s later, recovered: `status: recorded`, a 240-second movie of 3506 source pictures, `recovery: {restarts: 1, gaps: [{atSeconds: 27.184, seconds: 7.153, reason: stream-ended}]}`, and the last session's stop acknowledged with its stream gone. Whether that restart needed the stop by identifier or found no session left is not in the result; only that the lost session's end was confirmed one way or the other before the new one opened.

## Live checks owed

The cable pull on the cable route is done (above). The still screen on the iPhone 13 mini is measured: for a minute of the probe's unchanged list, pictures arrived a median of 98 ms apart and never more than 119 ms ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)), so a phone's still screen is not silent and 3 s without a packet is about 25 times the longest gap seen. The Apple TV 4K's is the opposite: its still screen sent no video after about five seconds, only one repeated packet once a second ([record](verification.md#the-apple-tvs-still-screen-and-a-restart-it-did-not-need)). So silence cannot be a trigger there, and stays no trigger anywhere until the human owner decides otherwise; on a phone it could be one. Still owed on the iPhone 13 mini, with a moving screen: end the stream from the device by opening Device Hub's screen view of it mid-recording (the device gives the screen to the newest client).
