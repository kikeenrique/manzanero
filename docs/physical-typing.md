# Physical text entry

Use `type` for clipboard-free US-layout ASCII keyboard events. Use [paste](native-input.md#direct-unicode-paste) for Unicode text when replacing the device clipboard is acceptable.

## Current direct implementation

```sh
manzanero physical <UDID> type 'Ab9!z'
manzanero physical <UDID> key backspace
manzanero physical <UDID> paste 'mañana 🚀 中'
```

`type` and MCP `type_text` with `platform: physical` use the in-process CoreDevice/Indigo keyboard route. No virtual keyboard registration, helper executable or clipboard write is used.

Typing accepts `1...512` printable US-layout ASCII characters, tab and LF newline. It rejects other Unicode; use the explicit paste operation rather than expecting an automatic fallback.

## Focus and layout

Typing acts at the current focus. It does not focus a field, select all, inspect the value, change hardware-keyboard layout or manage Caps Lock. The phone's keyboard layout, input method and application can change the resulting text.

Tab may move focus; LF generates Return and can submit a form. Choose a non-sensitive field and inspect the result before issuing follow-up actions.

## Scheduling and cleanup

The complete string is validated before device access. Each character maps to a Keyboard/Keypad HID usage; shifted characters bracket the key with Left Shift. Keys release between characters.

Events use absolute monotonic offsets spaced by 10 ms. The worst supported case has 2048 events over 20.47 seconds. Those are requested host times, not guaranteed device delivery times. The C boundary independently checks usages, counts, balanced transitions and complete release.

Cancellation or transport failure stops future typing and attempts release of the outstanding key set. The operation never replays a partial string. Forced exit, crashes or transport loss can prevent cleanup, and already-entered text is not rolled back. See [input cancellation](native-input.md#task-cancellation-and-release-attempts).

## Result and evidence

The receipt contains counts and `layout: US`, not the supplied text. `verified`, `insertionVerified` and `releaseVerified` remain false.

CLI and real MCP mixed-case/digit/punctuation strings were visually checked in Settings search on iPhone 13 mini, then cleared. This is scoped evidence, not complete punctuation/layout/field coverage or maximum-length delivery.

```sh
mise run test:mcp-type <UDID> 'mCp2!x'
```

The live task types into the current field and saves screenshots/receipt under ignored `tmp/`. It does not choose or clear a field for you. Do not use secrets as test text.

## Historical implementation

The retired Rust bridge registered an owned virtual mainKeyboard and attempted reset/removal. That runtime path is blocked. Its cleanup and layout assumptions are not the current Indigo implementation's guarantees.
