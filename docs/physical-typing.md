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

**Do not assume `us`.** A phone picks a layout without anyone choosing one, probably from its language: the test iPhone 13 mini, set to Spanish, applied Spanish – ISO, so the default `us` typed wrong punctuation there while `--layout spanish-iso` typed every character exactly, including Shift, Option and dead keys ([verification](verification.md#keyboard-layouts-on-the-phone)). Find it with `detect-layout` first.

## Finding the layout: `detect-layout`

```sh
manzanero launch com.lemambo.manzanero.probeapp --device <UDID>
manzanero detect-layout --id probe.text.field --device <UDID>
manzanero type --layout spanish-iso '¿Qué? <º> @€' --device <UDID>
```

`detect-layout` (MCP `detect_keyboard_layout`) types a short probe into one named text field, reads what arrived and compares it with what every keyboard layout on this Mac would have typed. It works on physical devices and simulators. The field is named with `--id` or `--label`, and `--index` (MCP `index`) chooses among several that match, by position; `--with-value` is refused, because the probe changes the field's value.

- **The probe** is computed from the Mac's layouts when the command runs: a greedy choice of letter, digit and punctuation keys, with and without Shift, that splits the layouts into as many groups as possible. Never Option, Return, Tab, Escape, space or arrows; a key that types a control character in any layout is not used; ties prefer keys that are not letters; and no layout may be left with a dead key pending at the end. On the test Mac it is 12 keys and tells the 262 layouts apart in 215 groups. `--dry-run` prints the keys and group counts without contacting the device.
- **Steps.** Read the field's value from the tree; `set-value` it to `x`, with the guards of `press` and the settable check (this focuses it with the caret at the end, and keeps the probe from starting a sentence); type the probe as HID keyboard events; read the field again and take what follows the `x`; compare.
- **Result.** `status` is `detected` (one layout; `layoutOption` is the `--layout` value to use), `ambiguous` (several layouts that type the same probe; all are listed, and they can still differ on keys the probe does not press, such as Option ones) or `no-match` (with the text that `arrived` and hints). It never picks one of several. The ten US-like layouts (`us`, `abc`, `us-extended`, `australian`, `canadian`, `dutch`, `brazilian`, `polish-pro`, `turkish-qwerty`, `unicode-hex-input`) differ only under Option, so a US device comes back `ambiguous` among them; any of them types the same non-Option characters.
- **Restore.** It deletes what the field holds with that many backspaces and reads it again. An empty field reads as its placeholder, so getting the first value back means the field was empty and is restored (`cleared-to-original`); otherwise the first value is set back with `set-value` (`set-value`). `restore.confirmed` says whether the read-back matched. If the backspaces did not all arrive, it stops with `not-cleared` rather than write the placeholder as text. Cancellation (SIGINT, SIGTERM, MCP) still restores, and says so on stderr. No setting is read or changed on a physical device.
- **Simulator.** The simulator's own `hw=` setting is reported in `deviceSetting`, with `agrees` when it names a layout; `hw=Automatic` names none.
- **Which field.** Autocorrection, auto-capitalisation, smart quotes and dashes, input methods (Japanese, Chinese, Korean) and fields that filter or reformat input all change what arrives. Use a plain text field with those off; the probe app's `probe.text.field` is the reference. A field that does not keep `x` as set is refused before typing. When nothing matches but a layout would after undoing a case change or smart punctuation, the result lists it under `matchesAfterUndoing`, as a hint only.

It sends input (about 30 key events and up to two set-values) and takes the device lease. The steps are existing operations run one after another, so it takes 7–9 seconds.

What is verified: US, Spanish – ISO, German, French and Latin American on a simulator ([verification](verification.md#keyboard-layouts-on-the-simulator)); Spanish – ISO on one phone, which used the ISO keyboard type like the simulator (the key left of Z arrived). Other layouts on a phone, and changing the phone's layout in Settings, are untested. `detect-layout` found Spanish – ISO on that phone and the explicit setting on a simulator in four settings ([verification](verification.md#layout-detection)).

## Focus and other state

Typing acts at the current focus. It does not focus a field, select all, inspect the value, change the hardware-keyboard layout or manage Caps Lock. Caps Lock, input methods (Japanese, Chinese, Korean), autocorrection and the application can change the resulting text.

Tab may move focus; LF generates Return and can submit a form. Choose a non-sensitive field and inspect the result before issuing follow-up actions.

## Scheduling and cleanup

The complete string is validated before device access. Each character maps to one or two Keyboard/Keypad HID usages; Left Shift and Left Option bracket a key that needs them, and every key is released before the next. A dead-key character is two such strokes.

Events use absolute monotonic offsets spaced by 10 ms. A schedule holds at most 2048 events (20.47 seconds), the former worst case of 512 shifted characters; Option and dead-key characters need four to twelve events each, so a long text of them is refused with the count and should be split. Those are requested host times, not guaranteed device delivery times. The C boundary independently checks usages (main block, arrows, Non-US backslash 100, Left Shift, Left Option, Left Command), counts, balanced transitions and complete release.

Cancellation or transport failure stops future typing and attempts release of the outstanding key set. The operation never replays a partial string. Forced exit, crashes or transport loss can prevent cleanup, and already-entered text is not rolled back; after a typing failure with an unknown outcome, or a typing process that died, input to the device is refused until [`clear-quarantine`](native-input.md#quarantine-after-an-uncertain-release). A cancellation between the two strokes of a dead-key character can leave the dead key pending on the device. See [input cancellation](native-input.md#task-cancellation-and-release-attempts).

## Result and evidence

The receipt contains counts, `layout` (the name), `layoutIdentifier` (the macOS identifier) and `deviceLayout`, not the supplied text. `verified`, `insertionVerified` and `releaseVerified` remain false. The dry-run plan has the same layout fields and `deviceLayoutCheck`.

CLI and real MCP mixed-case/digit/punctuation strings were visually checked in Settings search on iPhone 13 mini with the former US table, then cleared. Letters, digits and `!` are the same in US and in Spanish – ISO, which that phone uses, which is the likely reason those checks looked right. With `--layout spanish-iso`, a 76-character punctuation string and texts with Shift, Option and dead keys read back exactly from the probe's field ([verification](verification.md#keyboard-layouts-on-the-phone)). This is scoped evidence, not complete layout/field coverage or maximum-length delivery; MCP `type_text` with a layout has not been run against a phone.

```sh
mise run test:mcp-type <UDID> 'mCp2!x'
mise run test:mcp-type <UDID> 'Año ¿qué? <º>' spanish-iso
```

The live task types into the current field and writes its screenshots and receipt as working files under `tmp/`. It does not choose or clear a field or change the phone's layout. Do not use secrets as test text.

## Historical implementation

The retired Rust bridge registered an owned virtual mainKeyboard and attempted reset/removal. That path has been removed. Its cleanup and layout assumptions are not the current Indigo implementation's guarantees.
