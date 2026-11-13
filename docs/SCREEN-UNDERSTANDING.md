# Screen inspection

Current runtime: screenshot capture and Vision OCR run through Apple tools/frameworks without a device helper. Physical foreground trees and simulator helper-based hierarchies are unavailable under the current executable policy, so `auto` falls back to OCR. The opt-in direct explicit-PID tree command is separate and still fails endpoint access on the tested phone; it is not integrated as a foreground screen tree. Historical hierarchy observations below remain migration evidence.

```sh
appledevicescmd simulator <UUID> screen auto
appledevicescmd simulator <UUID> screen tree
appledevicescmd physical <device> screen ocr
appledevicescmd physical <device> screen auto
appledevicescmd physical <device> screen tree
```

The command saves a fresh screenshot beneath a unique `tmp/screen-*/` directory, checks that it decodes as PNG, and returns JSON with the image path, pixel dimensions, capture time, analysis method, coordinate space, and diagnostics. Simulator targets require an explicit UUID. Physical capture uses Xcode and its readiness preflight. Historical physical hierarchy analysis required the now-disabled idevice executable; capture and forced OCR do not.

In `auto` mode, a simulator hierarchy is useful when at least one non-application node has a role/type and a nonempty label, identifier, value, or title. The original AXe hierarchy is returned without rewriting it. Physical auto uses a [foreground physical tree](ACCESSIBILITY-PROTOCOL.md#active-per-application-tree), selecting the primary display-centre process without a caller-supplied PID. It requires consistent tree metadata and a non-root node that is not marked hidden and has a nonempty label, identifier, or string value. The hierarchy is preserved, and any cleanup warning also appears in diagnostics. An unavailable, malformed, empty, or application-only hierarchy falls back to Vision OCR. These heuristics do not prove every visible control is represented. The raw `ax-snapshot` archive is not a parsed hierarchy.

If OCR also fails in automatic mode, the result contains `method: image-only`, `status: partial`, and diagnostics. It never invents text or a hierarchy. Successful analysis reports `status: captured`; an empty OCR result is accompanied by a diagnostic. Forced `tree` or `ocr` failures return an error that identifies the saved screenshot. Both platforms accept forced `tree`. Cancellation propagates as cancellation rather than partial success.

MCP `get_screen` accepts `platform`, `device`, and optional `method` (`auto`, `tree`, or `ocr`). JSON appears under `structuredContent.result`, with the saved PNG included as image content up to 8 MiB. Larger PNGs remain on disk with an omission notice. Captures can contain private device content; keep `tmp/` out of version control.

## Coordinates and consistency

- Accessibility coordinates are simulator interface points or physical device logical points. Screenshot dimensions are image pixels; they can differ by the display scale factor.
- OCR bounds are normalized 0...1, with the origin at the top left. They describe text regions, not interactive hit targets.
- Image-only output identifies image-pixel coordinates.

No automatic conversion from OCR bounds to simulator tap points, stable element references, or OCR selector taps is provided. Capture and hierarchy queries occur sequentially, so a changing screen can produce different states. The timestamp describes capture completion, not an atomic capture-and-tree transaction. OCR has no separate deadline; cold startup can be slow.

## Verification

Simulator auto mode returned the tool-owned fixture's accessibility hierarchy and a decoded 1206×2622 PNG. Forced OCR recognized the fixture text with confidence 1.0. The real MCP stdio test exercised `get_screen` and received hierarchy data plus inline PNG content. Synthetic tests cover fallback, invalid capture, forced-method failure, cancellation, and generated image-path handling.

Before the non-Apple executable restriction, physical auto selected Settings without a caller-supplied PID and returned accessibility data with a 1125×2436 PNG and logical-point geometry on the awake/unlocked USB iPhone 13 mini. The real `test:mcp-foreground` exchange verified both `get_ui_tree` and `get_screen`, including inline PNG content. These historical checks do not establish current hierarchy availability, physical OCR accuracy or complete screen coverage.

On 2026-11-13, direct CLI `screen ocr` captured the selected iPhone 13 mini at 1125×2436 and recognized visible Spanish Settings labels, including General, Batería and Buscar. Independent image inspection matched those labels and their top-left normalized bounds. A native list scroll moved Settings; a fresh OCR result for Pantalla y brillo supplied a visually checked centre, and one direct tap opened Display & Brightness. A fresh screenshot and OCR confirmed the new page. This is scoped physical recognition/navigation evidence, not general accuracy, semantic assertions or a product OCR selector action.

Two earlier taps at the visible General text centre (one Indigo tap and one explicit Universal HID schedule) left the root page visible; their cause remains unresolved. One later Home dispatch also left Display & Brightness visible despite a successful receipt. Other Home, touch and scroll checks in the same run did take effect. The negative results are retained alongside successes: OCR bounds do not establish hittability, and dispatch receipts do not prove UI effects or reliable delivery. See [verification records](VERIFICATION.md).

An earlier standalone OCR attempt failed with `Failed to create CVPixelBuffer`; its cause remains unknown. Initial black captures preceded the user's confirmed wake/unlock; their exact cause was not isolated. The successful current Settings checks do not erase these earlier failures or establish all-app/orientation/device coverage.
