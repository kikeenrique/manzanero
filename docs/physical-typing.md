# Physical text entry

Use `type` for clipboard-free keyboard events at the current focus, in the keyboard layout the device uses. For text no layout types, use `set-value`, which replaces a named field's whole value through accessibility, or [paste](native-input.md#direct-unicode-paste) when the text must go to the current focus and replacing the device clipboard is acceptable.

## Current direct implementation

```sh
manzanero type 'Ab9!z' --device <UDID>
manzanero type --layout spanish-iso 'Año ¿qué?' --device <UDID>
MANZANERO_KEYBOARD_LAYOUT=german manzanero type 'Grüße' --device <UDID>
manzanero keyboard-layouts
manzanero key backspace --device <UDID>
manzanero set-value --id <identifier> 'mañana 🚀 中' --device <UDID>
manzanero paste 'mañana 🚀 中' --device <UDID>
```

`set-value` is the same operation as on a simulator, with the same guards, receipt and limits; see [set-value](simulator-input.md#unicode-text-set-value). On a physical device it selects the app at the display centre, as `press` does, and takes the device lease.

`type` and MCP `type_text` with `platform: physical` use the in-process CoreDevice/Indigo keyboard route. No virtual keyboard registration, helper executable or clipboard write is used.

## Layouts

The device turns key codes into characters with its own hardware-keyboard layout (Settings › General › Keyboard › Hardware Keyboard), so the caller names that layout: `--layout <name>`, else `MANZANERO_KEYBOARD_LAYOUT`, else `us`. MCP `type_text` takes a `layout` field (default `us`) and does not read the server's environment. Names are those `manzanero keyboard-layouts` (MCP `list_keyboard_layouts`) prints, such as `us`, `spanish-iso`, `german`, `french`, `british`, `us-international-pc`; case, spaces and punctuation are ignored, so the iOS name `Spanish - ISO` works too. Note that Apple's `spanish` is the legacy Spanish layout; modern Spanish keyboards are `spanish-iso`.

The character table comes from the macOS layout of that name ([research](keyboard-layouts.md)): every character the layout produces plainly, with Shift, with Option, with Shift+Option, or with one dead key followed by one key, plus tab and LF newline. Text is `1...512` characters; the first character the layout cannot produce refuses the whole text before any device access, with a message naming it and its position and pointing to `set-value`. Each character's strokes are translated again before sending, so the schedule produces exactly the text on a device that uses that layout. For `us`, ASCII text gives exactly the schedule of the former fixed US table.

**The device's own layout is not read on a physical device.** No Apple tool exposes it; the receipt's `deviceLayout` says `not-read`, and the text is right only if the phone uses the named layout. A wrong name types wrong characters without any error. (On a simulator the setting is read and a different explicit layout is refused; see [simulator input](simulator-input.md#keyboard-layouts).)

What is verified: layouts were checked live on a simulator only (US, Spanish – ISO, German, French, Latin American; [verification](verification.md#keyboard-layouts-on-the-simulator)). On a phone, only US ASCII has been typed. In particular the phone's keyboard type is unknown: 13 layouts (Latin American, Turkish – Standard and others) give different characters on the key left of 1 and the key left of Z depending on it, and the simulator used the ISO type.

## Focus and other state

Typing acts at the current focus. It does not focus a field, select all, inspect the value, change the hardware-keyboard layout or manage Caps Lock. Caps Lock, input methods (Japanese, Chinese, Korean), autocorrection and the application can change the resulting text.

Tab may move focus; LF generates Return and can submit a form. Choose a non-sensitive field and inspect the result before issuing follow-up actions.

## Scheduling and cleanup

The complete string is validated before device access. Each character maps to one or two Keyboard/Keypad HID usages; Left Shift and Left Option bracket a key that needs them, and every key is released before the next. A dead-key character is two such strokes.

Events use absolute monotonic offsets spaced by 10 ms. A schedule holds at most 2048 events (20.47 seconds), the former worst case of 512 shifted characters; Option and dead-key characters need four to twelve events each, so a long text of them is refused with the count and should be split. Those are requested host times, not guaranteed device delivery times. The C boundary independently checks usages (main block, arrows, Non-US backslash 100, Left Shift, Left Option, Left Command), counts, balanced transitions and complete release.

Cancellation or transport failure stops future typing and attempts release of the outstanding key set. The operation never replays a partial string. Forced exit, crashes or transport loss can prevent cleanup, and already-entered text is not rolled back. A cancellation between the two strokes of a dead-key character can leave the dead key pending on the device. See [input cancellation](native-input.md#task-cancellation-and-release-attempts).

## Result and evidence

The receipt contains counts, `layout` (the name), `layoutIdentifier` (the macOS identifier) and `deviceLayout`, not the supplied text. `verified`, `insertionVerified` and `releaseVerified` remain false. The dry-run plan has the same layout fields and `deviceLayoutCheck`.

CLI and real MCP mixed-case/digit/punctuation strings were visually checked in Settings search on iPhone 13 mini with the former US table, then cleared. This is scoped evidence, not complete punctuation/layout/field coverage or maximum-length delivery.

```sh
mise run test:mcp-type <UDID> 'mCp2!x'
mise run test:mcp-type <UDID> 'Año ¿qué? <º>' spanish-iso
```

The live task types into the current field and saves screenshots/receipt under ignored `tmp/`. It does not choose or clear a field or change the phone's layout. Do not use secrets as test text.

## Historical implementation

The retired Rust bridge registered an owned virtual mainKeyboard and attempted reset/removal. That path has been removed. Its cleanup and layout assumptions are not the current Indigo implementation's guarantees.
