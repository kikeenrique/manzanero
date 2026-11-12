# Screen inspection

```sh
appledevicescmd simulator <UUID> screen auto
appledevicescmd simulator <UUID> screen tree
appledevicescmd physical <device> screen ocr
```

The command saves a fresh screenshot beneath a unique `tmp/screen-*/` directory, checks that it decodes as PNG, and returns JSON with the image path, pixel dimensions, capture time, analysis method, coordinate space, and diagnostics. Simulator targets require an explicit UUID. Physical capture uses Xcode and its readiness preflight; it does not require the idevice bridge.

In `auto` mode, a simulator hierarchy is useful when at least one non-application node has a role/type and a nonempty label, identifier, value, or title. The original AXe hierarchy is returned without rewriting it. An unavailable, malformed, empty, or application-only hierarchy falls back to Vision OCR. This heuristic does not prove every visible control is represented. Physical auto mode selects OCR directly; the raw `ax-snapshot` archive is not a parsed hierarchy.

If OCR also fails in automatic mode, the result contains `method: image-only`, `status: partial`, and diagnostics. It never invents text or a hierarchy. Successful analysis reports `status: captured`; an empty OCR result is accompanied by a diagnostic. Forced `tree` or `ocr` failures return an error that identifies the saved screenshot. Physical `tree` is rejected before capture. Cancellation propagates as cancellation rather than partial success.

MCP `get_screen` accepts `platform`, `device`, and optional `method` (`auto`, `tree`, or `ocr`). JSON appears under `structuredContent.result`, with the saved PNG included as image content up to 8 MiB. Larger PNGs remain on disk with an omission notice. Captures can contain private device content; keep `tmp/` out of version control.

## Coordinates and consistency

- Accessibility coordinates are simulator interface points. Screenshot dimensions are image pixels; they can differ by the simulator scale factor.
- OCR bounds are normalized 0...1, with the origin at the top left. They describe text regions, not interactive hit targets.
- Image-only output identifies image-pixel coordinates.

No automatic conversion from OCR bounds to simulator tap points, stable element references, or OCR selector taps is provided. Capture and hierarchy queries occur sequentially, so a changing screen can produce different states. The timestamp describes capture completion, not an atomic capture-and-tree transaction. OCR has no separate deadline; cold startup can be slow.

## Verification

Simulator auto mode returned the tool-owned fixture's accessibility hierarchy and a decoded 1206×2622 PNG. Forced OCR recognized the fixture text with confidence 1.0. The real MCP stdio test exercised `get_screen` and received hierarchy data plus inline PNG content. Synthetic tests cover fallback, invalid capture, forced-method failure, cancellation, and generated image-path handling.

These checks establish one simulator fixture, not general OCR accuracy. An earlier standalone OCR attempt failed with `Failed to create CVPixelBuffer`; its cause remains unknown. The prepared iPhone 13 mini initially produced a black 1125×2436 PNG with no OCR text. After the user confirmed wake/unlock, fresh screenshots showed Settings and Home content and allowed native input verification. The black capture's exact cause was not isolated; physical text recognition remains unverified. See [verification records](VERIFICATION.md).
