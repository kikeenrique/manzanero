# Screen inspection and OCR

`screen` captures a PNG, then analyzes it with accessibility or Vision OCR. It gives an agent a saved image and explicit information about how the screen was interpreted.

```sh
manzanero screen auto --device <UDID>
manzanero screen tree --device <UDID>
manzanero screen ocr --device <UDID>
manzanero screen auto --simulator <UUID>
manzanero ocr tmp/existing.png
```

Simulator screen inspection requires an explicit UUID. Physical capture uses Xcode and its preparation checks. The hierarchy comes from native Apple AX on both platforms: over the device's accessibility session on a phone, and through CoreSimulator on a simulator ([simulator input](simulator-input.md)). On a simulator with several displays (iPhone Duo), `--display` chooses the captured display; the tree describes only the display the interface is on, so with another display `auto` uses OCR and `tree` is refused before capture ([other families](other-families.md#displays-iphone-duo)).

## Choosing a method

| Method | Behavior |
| --- | --- |
| `auto` | Prefer a useful hierarchy; otherwise use OCR. If both fail, retain the PNG as an explicit image-only partial result. |
| `tree` | Require a hierarchy; on failure, return an error with the retained image path. |
| `ocr` | Require Vision recognition; on failure, return an error with the retained image path. |

A useful physical tree must contain meaningful non-root, non-hidden content with consistent metadata. That heuristic does not prove complete coverage. Empty/application-only, malformed or unavailable trees cause automatic OCR fallback; the raw callback archive is not a hierarchy.

The screenshot precedes the hierarchy query. These are different observations of a changing UI, not an atomic transaction. Native AX subscription/tunnel cleanup uncertainty is preserved in diagnostics.

## Output

A physical `screenshot` receipt is `devicectl`'s JSON with two fields added: `displayPower` (`on`, `off`, `unknown`, or `external` for an Apple TV's television, read once right after the capture) and, when it is `off`, a `displayNote`. A sleeping phone answers a screenshot with a black image and no error, so check the field, or `wake` first. A sleeping Apple TV fails the screenshot instead, with "Display reports zero-sized native size" ([Apple TV](other-families.md#a-physical-apple-tv)).

Since 2026-11-23 the receipt also says `blankImage`: true when every pixel of a 256-pixel thumbnail of the picture is dark (no channel above 12 of 255), false otherwise, absent when the file could not be read. A blank picture gets a `blankNote` unless the display was reported off, which has its own note. On an Apple TV the note says that the device is not asleep, since it gave a picture, so the screen is black or protected video (FairPlay) is on screen: the device leaves protected content out of captures, interface and all, and no capture of the interface alone exists. Which of the two it is cannot be read from the picture; read the tree. Added after an agent's screenshots over a streaming app's video came back black with nothing to say why. After a blank picture from an Apple TV the tool reads one tree and adds `playerOnScreen`: true when it shows Apple's player (class names `_AVPlayerViewControllerContainerView`, `__AVPlayerLayerView` or `AVNowPlayingTransportBar` in native attribute 5003, or the transport bar's `Media Controls`, `Scrub Needle` or `AXElapsedTime`), and the note then names protected video as the likely cause. Those markers were read from the tvOS probe's [silent video](probe-app.md#a-silent-video) on a simulator ([record](verification.md#seeking-in-apples-player-on-a-simulator)); a player an app draws itself on a bare `AVPlayerLayer` may show none of them, so false does not rule protected video out. The tree goes over the tool's own tunnel only, as every Apple TV accessibility command; without it the receipt says why in `playerCheckUnavailable`. Unit-tested; not yet run over protected video on the Apple TV 4K.

Images are saved under a new `tmp/screen-<UUID>/` directory. JSON includes image path, decoded pixel dimensions, capture time, selected method, coordinate space and diagnostics. Successful analysis reports `status: captured`; automatic image-only fallback reports `status: partial`. An empty OCR result has an explicit diagnostic.

MCP `get_screen` accepts `platform`, `device` and optional `method` and `display`. JSON appears under `structuredContent.result`; the saved PNG stays full resolution, and a reduced copy (longest edge 1568 pixels by default) is included as image content, adjustable per call (see [inline image options](mcp.md#inline-image-options)).

## Coordinate spaces

- Physical AX frames: device logical points.
- OCR bounds: normalized `0...1`, origin at the top left.
- Image-only dimensions: pixels.

A screenshot's pixel dimensions can differ from AX geometry by its display scale. OCR regions describe text, not hittable controls. There is no automatic OCR selector tap or stable action handle.

## OCR deadlines

Recognition has a 120-second cooperative deadline after the local readability check. Expiry requests cancellation, rejects late output and drains the recognition task. Apple Vision may delay cancellation; this is not a hard wall-clock bound. Screenshot/hierarchy work is outside that recognition deadline.

Caller cancellation remains cancellation. Automatic OCR failure retains the image-only result; forced OCR failure reports the retained image path.

```sh
mise run test:ocr <local-image>
mise run test:ocr <local-image> --timeout-ms 10 --expect-timeout
```

These tests query no device. The short deadline does not prove recognition had begun before cancellation.

## Evidence and troubleshooting

Native physical `screen auto`/`tree` returned Settings hierarchy and PNG through real MCP on iPhone 13 mini. Direct OCR recognized Spanish Settings labels with visually checked bounds. An OCR-guided tap opened Display & Brightness after fresh observation.

Several taps at visible General text initially had no effect, and one Home dispatch also left the current page visible. Repositioning by a separately inspected scroll led to later successful navigation; the cause of the misses was not established. An earlier OCR attempt failed with `Failed to create CVPixelBuffer`; initial black screenshots preceded confirmed wake/unlock.

When an action has no observed effect, inspect a fresh image and reassess the target/overlays before choosing another action. Do not automatically replay a tap based on an old OCR box. See [verification](verification.md) for the scope of the positive and negative checks.

Screen data can be private. Keep `tmp/` ignored and review captures before sharing.
