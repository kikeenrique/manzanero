# Screen inspection and OCR

`screen` captures a PNG, then analyzes it with accessibility or Vision OCR. It gives an agent a saved image and explicit information about how the screen was interpreted.

```sh
appledevicescmd physical <UDID> screen auto
appledevicescmd physical <UDID> screen tree
appledevicescmd physical <UDID> screen ocr
appledevicescmd simulator <UUID> screen auto
appledevicescmd ocr tmp/existing.png
```

Simulator screen inspection requires an explicit UUID. Physical capture uses Xcode and its preparation checks. The current physical hierarchy provider is native Apple AX; simulator hierarchy is unavailable because the old AXe executable is blocked.

## Choosing a method

| Method | Behavior |
| --- | --- |
| `auto` | Prefer a useful hierarchy; otherwise use OCR. If both fail, retain the PNG as an explicit image-only partial result. |
| `tree` | Require a hierarchy; on failure, return an error with the retained image path. |
| `ocr` | Require Vision recognition; on failure, return an error with the retained image path. |

A useful physical tree must contain meaningful non-root, non-hidden content with consistent metadata. That heuristic does not prove complete coverage. Empty/application-only, malformed or unavailable trees cause automatic OCR fallback; the raw callback archive is not a hierarchy.

The screenshot precedes the hierarchy query. These are different observations of a changing UI, not an atomic transaction. Native AX subscription/tunnel cleanup uncertainty is preserved in diagnostics.

## Output

Images are saved under a new `tmp/screen-<UUID>/` directory. JSON includes image path, decoded pixel dimensions, capture time, selected method, coordinate space and diagnostics. Successful analysis reports `status: captured`; automatic image-only fallback reports `status: partial`. An empty OCR result has an explicit diagnostic.

MCP `get_screen` accepts `platform`, `device` and optional `method`. JSON appears under `structuredContent.result`; the saved PNG is included as image content up to 8 MiB. Larger images stay on disk with an omission notice.

## Coordinate spaces

- Physical AX frames: device logical points.
- Simulator hierarchy frames, when a provider is available: interface points.
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

When an action has no observed effect, inspect a fresh image and reassess the target/overlays before choosing another action. Do not automatically replay a tap based on an old OCR box. See [verification](VERIFICATION.md) for the scope of the positive and negative checks.

Screen data can be private. Keep `tmp/` ignored and review captures before sharing.
