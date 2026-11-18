# Keyboard layouts for `type`

> **Status (2026-11-16):** research note, kept as written. Built from it: `type --layout`, `keyboard-layouts` and `detect-layout`; the current guide is [physical typing](physical-typing.md#layouts). After it was written, the iPhone 13 mini typed Spanish – ISO exactly, including Shift, Option and dead keys, and the key left of Z arrived, so that phone uses the ISO keyboard type like the simulator ([verification](verification.md#keyboard-layouts-on-the-phone)). Other layouts on a phone remain unchecked.

`type` sends HID key usages; the device turns them into characters with its own hardware-keyboard layout. A table that assumes US therefore types wrong text whenever the device uses another layout. This note records what was found about where that layout lives, whether it can be read or set, and whether a character table for any layout can be built with Apple frameworks only. Each finding is marked **observed** (seen on this machine) or **inferred** (concluded, not seen).

Machine and versions: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), iOS 27.2 simulator runtime (build 24B8117), an `iPhone 17e` simulator. No physical device was used. The programs named below were throwaway and are not part of the project. What `type` does with these findings is in [physical typing](physical-typing.md#layouts); the live checks are in [verification](verification.md#keyboard-layouts-on-the-simulator).

## Summary

- **A table for any layout can be built from macOS's own layouts.** The Text Input Sources API (`TISCreateInputSourceList`, `kTISPropertyUnicodeKeyLayoutData`) gives each layout's `uchr` data; `UCKeyTranslate` turns (key, modifiers, dead-key state) into text. Mapping the Mac virtual key codes back to HID usages gives the strokes `type` sends. (observed)
- **The iOS 27.2 runtime ships the same layouts.** Its `USBKeyboardLayouts.bundle` holds 253 `uchr` files indexed by HID usage instead of Mac key code. For every one of the 252 that has a macOS counterpart, the table of typeable characters and their strokes (plain, Shift, Option, Shift+Option, and one dead key followed by one key) was identical to the macOS table built through the HID mapping below, with the same keyboard type on both sides. (observed)
- **The simulator translates with the ISO keyboard type.** In Latin American, whose ANSI and ISO tables differ, HID 53 typed `<` (ISO), not `|` (ANSI). (observed, after this note was first written)
- **Simulator: the layout is a preference that can be read and set.** It is the `hw=` part of the current input mode in `com.apple.keyboard.preferences`. An explicit value (`hw=German`) is honoured; `hw=Automatic`, the default, is resolved by iOS in a way that could not be predicted. (observed)
- **Physical device: no Apple tool reads it.** `devicectl` exposes no preferences domain; the layout cannot be read. (inferred from `devicectl` help; no phone was used) It can be detected by typing instead: `detect-layout` ([below](#detecting-the-layout-by-typing)).

So the requirement can be met with the caller naming the layout: the table is exact for the layouts macOS ships, a simulator's explicit layout can be checked before sending, and everything else must be stated as unverified in the receipt.

## Where the layout comes from

**Simulator (observed).** The simulator's `com.apple.keyboard.preferences` domain holds the input modes, each a string such as `de_DE@sw=QWERTZ-German;hw=Automatic` (`sw` is the on-screen layout, `hw` the hardware one). The current one is `KeyboardLastUsed`, with `KeyboardsCurrentAndNext` listing it first. `AppleKeyboards` in the global domain lists the enabled modes. A fresh `iPhone 17e` had only `KeyboardsCurrentAndNext = (en_US@sw=QWERTY;hw=Automatic, …)` and typed US.

Read it with `xcrun simctl spawn <UUID> defaults export com.apple.keyboard.preferences -` (about 0.5 s) or `defaults read … KeyboardLastUsed`. The plist under the simulator's data directory was current as well, but `defaults` goes through the simulator's own `cfprefsd`.

What changed typing (always after relaunching the app):

| Setting | Typed `-;yz` (HID 45, 51, 28, 29) gave | Layout |
| --- | --- | --- |
| default `en_US@sw=QWERTY;hw=Automatic` | `-;yz` | US |
| `de_DE@sw=QWERTZ-German;hw=Automatic` | `ßözy` (with `yz-` → `zyß`) | German |
| `es_ES@sw=QWERTY-Spanish;hw=Automatic` | `'ñyz` | Spanish – ISO |
| `es_ES@sw=QWERTY-Spanish;hw=German` written with `defaults write` | `ßözy` | German: explicit `hw` wins over the language |
| `es_419@sw=QWERTY-Spanish;hw=Automatic;ml=120` | `[a;` typed as `[a;` | US, although the runtime lists `Latin American` first for `es_419` |

- `hw=<name>` uses the iOS layout names of `USBKeyboardLayouts.plist` (`US`, `German`, `Spanish - ISO`, `French`, …). Every one of the 253 names equals a macOS layout identifier (`com.apple.keylayout.<id>`) once both are reduced to lowercase letters and digits (`Spanish - ISO` and `Spanish-ISO` → `spanishiso`). (observed)
- `hw=Automatic` is resolved by iOS. The runtime's `TextInput_<lang>.bundle/InputMode_<lang>.plist` gives each mode a `Hardware.Layout` or a `HWLayouts` list, which matched the German and Spanish results but not the multilingual `es_419` mode (`ml=120`), which typed US. Manzanero does not try to resolve `Automatic`. (observed)
- **A running app keeps its layout.** After switching from German to Spanish, the already-running probe app still typed German until it was relaunched. A preference read therefore says what the setting is, not necessarily what the focused app uses. (observed)
- **Setting it.** `defaults write` of `AppleKeyboards`, `KeyboardLastUsed` and `KeyboardsCurrentAndNext` through `simctl spawn`, then relaunching the app, took effect. CoreSimulator's private `-[SimDevice setKeyboardLanguage:error:]` (sent to the simulator's CoreSimulatorBridge, which picks an input mode for the language, enables it and makes it current) also works and leaves `hw=Automatic`. Settings › General › Keyboard shows no Hardware Keyboard section on the simulator, because no hardware keyboard counts as attached (`-[SimDevice setHardwareKeyboardEnabled:keyboardType:error:]` exists but was not tried). Xcode 27.2 has no Simulator.app; its DeviceHub settings offer no keyboard-language option. (observed)

**Physical device (inferred).** Settings › General › Keyboard › Hardware Keyboard appears when a hardware keyboard is attached; Indigo keyboard events may or may not count as one, which was not checked. The layout is presumably stored in the same preference on the phone, but `devicectl` 27.2 reads no preferences: `device info` covers apps, displays, lock state, appearance, audio and similar, and `device info files` only the temporary, app data, app group and crash-log domains. The accessibility service does not expose it either. Manzanero therefore cannot read a phone's layout; the receipt says so.

**Host keyboard.** The Mac's own input source (here Spanish – ISO) did not reach the simulator: the simulator typed US until its own preference changed. (observed)

## Building the table

`TISCreateInputSourceList({type: keyboard layout}, includeAllInstalled: true)` returned 264 layouts on this Mac (262 distinct identifiers), all with `kTISPropertyUnicodeKeyLayoutData`. Their identifiers (`com.apple.keylayout.Spanish-ISO`) are stable; their localized names follow the host language (`Spanish-ISO` is shown as "Spanish", and `Spanish` as "Spanish – Legacy"). The calls returned the same data from the main thread, a detached thread, a global queue and a detached task, one after another. **Concurrent** calls from parallel tests aborted the test process, so Manzanero makes every Text Input Sources and `UCKeyTranslate` call under one lock and caches the list and built tables for the life of the process. (observed)

For each HID usage in the main block, the table asks `UCKeyTranslate(layout, macKeyCode, kUCKeyActionDown, modifiers, keyboardType, 0, &deadState, …)` with modifiers none, Shift, Option and Shift+Option:

- an output of one character with no dead state is a single stroke;
- a dead state is followed by every key and modifier again; an output of one character is a dead-key sequence (for example Option+E then E for `é` in US, or the acute key then E in Spanish – ISO).

Shortest sequences win, and among equals no modifier, then Shift, then Option, then Shift+Option, then the lower usage. Characters are compared by Unicode canonical equivalence, so a decomposed `é` asks for the same strokes as a precomposed one; the device types the precomposed form.

HID usage → Mac virtual key code used (main block only; the codes are the Mac's ANSI names, translated with keyboard type 41, ISO):

| HID | Keys | Mac |
| --- | --- | --- |
| 4…29 | A…Z | 0 A, 11 B, 8 C, 2 D, 14 E, 3 F, 5 G, 4 H, 34 I, 38 J, 40 K, 37 L, 46 M, 45 N, 31 O, 35 P, 12 Q, 15 R, 1 S, 17 T, 32 U, 9 V, 13 W, 7 X, 16 Y, 6 Z |
| 30…39 | 1…9, 0 | 18, 19, 20, 21, 23, 22, 26, 28, 25, 29 |
| 44…56 | space - = [ ] \ ; ' ` , . / | 49, 27, 24, 33, 30, 42, 41, 39, 50, 43, 47, 44 (50, Non-US #, not used) |
| 100 | Non-US \ (the key left of Z on ISO keyboards) | 10 |

Tab (43) and Return (40, for LF) are sent as today. Keypad keys, the Non-US # key (50), the JIS keys and Caps Lock are not used: their output depends on Num Lock, on the keyboard type or on state `type` does not manage.

**The comparison (observed).** A throwaway program, `compare.swift`, built both tables for every iOS layout: from the macOS `uchr` through the mapping above, and from the iOS `uchr` indexed by HID usage directly. With the same keyboard type on both sides (40 ANSI, 41 ISO or 42 JIS) all 252 were identical. Between ANSI and ISO, 13 layouts differ, only in which of HID 53 and 100 gives which character (Latin American, Turkish – Standard, Canadian French – PC, Russian – PC, Arabic – PC, Lithuanian, Uzbek – Cyrillic and others); JIS differs from ANSI in 116. Which type iOS applies was settled live: on the simulator, Latin American HID 53 typed `<`, `>` and `≤` (the ISO table) where ANSI predicts `|`, so the tables use type 41. Spanish – ISO, German and US are the same in both types. A phone was not checked; for those 13 layouts the two keys are what to check there.

Only one iOS layout name, `Arabic-North_Africa`, had no macOS file by the file-name rules of the comparison; it does match `com.apple.keylayout.Arabic-North_Africa` by the normalized name. Macs also list layouts that iOS lacks (Chinese and Korean input-method layouts such as `PinyinKeyboard`, `3SetHangul`, `ZhuyinEten`).

## Where iOS can differ from the macOS layout of the same name

- **Different iOS versions (inferred).** The comparison covers iOS 27.2 against macOS 27.2. A phone on another version can ship different files; Apple rarely changes a layout, but nothing checks it.
- **Keyboard type.** HID 53 and 100 differ between the ANSI and ISO tables of 13 layouts, as above. The simulator used ISO (observed); a phone's Indigo keyboard may not (inferred risk).
- **Input methods (inferred).** Layouts used under an input method (Japanese Kana, Chinese, Korean) produce marked text that the input method converts; the table types the layout's characters, not the method's result.
- **Option and dead keys.** The simulator applied the Option layer and composed dead keys from Indigo keyboard events in US, Spanish – ISO, German, French and Latin American (observed; see [verification](verification.md#keyboard-layouts-on-the-simulator)). Not checked on a phone.
- **Caps Lock and app behaviour.** Caps Lock state changes the case of letters; secure fields, autocorrection and apps that filter input can still change the result.

## Consequences for the design

- The caller names the layout (`--layout`, `MANZANERO_KEYBOARD_LAYOUT`, MCP `layout`), default `us`. Names are the macOS identifiers in lowercase with hyphens (`spanish-iso`, `german`, `french`, `us`); any spelling that reduces to the same letters and digits is accepted, including the iOS names. `keyboard-layouts` (MCP `list_keyboard_layouts`) lists them.
- The table is built from the host's layouts; each character's strokes are translated again, from the dead-key state the previous ones left, before anything is sent.
- On a simulator the current input mode is read first. An explicit `hw=` that names another layout is refused before input; `Automatic`, an unreadable preference, or a value without a macOS counterpart is reported in the receipt as not checked. On a physical device the receipt says the layout was not read.
- The `us` table gives exactly the former strokes for ASCII, so existing schedules do not change (a test compares all 95 printable characters, tab and LF with the former table).
- The schedule limit stays at 2048 events (20.47 s at 10 ms), the former worst case. Option and dead keys need more events per character, so 512 such characters can exceed it and are refused with the count.

## Detecting the layout by typing

A phone's layout cannot be read, but what it does with keys can be watched. `detect-layout` ([guide](physical-typing.md#finding-the-layout-detect-layout)) types a probe into a field, reads it back and compares it with the output of every layout on the Mac, built with the same `UCKeyTranslate` tables as `type`.

- **Choosing the keys.** The probe is designed greedily from the installed layouts when the command runs: at each step the key (main block except space, with or without Shift, never Option) that minimises the sum of squared group sizes, which is the expected number of layouts left; ties prefer non-letters, then no Shift, then the lower usage, so the result is fixed for a given Mac. A key whose output contains a control character in any layout is never used. The dead-key state is part of each layout's progress, so a dead key followed by another key is predicted as the layout predicts it; a sequence that would leave a dead key pending in some layout is finished with the key that resolves it best. On macOS 27.2.1 the probe is 12 keys (HID `47 53 18 49 52 ⇧32 20 46 29 ⇧35 51 34`); US types `` [`o\'#q=z^;5 ``, Spanish – ISO `` `<oç´·q¡z&ñ5 ``, German `ü<o#ä§q´y&ö5`, French `` ^<o`ù3a-w6m( ``. (observed)
- **What it can tell apart.** 262 layouts fall into 215 groups. The largest, ten US-like layouts (`us`, `abc`, `us-extended`, `australian`, `canadian`, `dutch`, `brazilian`, `polish-pro`, `turkish-qwerty`, `unicode-hex-input`), differ only under Option; German shares its group with `abc-qwertz` and `austrian`, French with `abc-azerty`, `belgian` and `french-numerical`, British with `irish`, `irish-extended` and `welsh`. Without Option no probe can split these. (observed)
- **Dead keys that do not compose.** In Spanish – ISO the probe presses the dead grave before `<` and the dead acute before `·`; `UCKeyTranslate` gives `` `< `` and `´·`, and both the simulator and the iPhone 13 mini typed exactly that. (observed)
- **What can make it fail.** Anything between the key and the field's text: autocorrection, auto-capitalisation (the probe follows an `x` set through accessibility, so it never starts a sentence), smart punctuation, input methods, fields that filter input, and a phone whose iOS version ships a different table. The result is then `no-match`, never a nearby layout.

## Options that were not taken

- **Reading the iOS runtime's own `uchr` files** instead of the macOS layouts. They are exactly what the simulator uses, but exist only where an iOS simulator runtime is installed, and a phone may run another version anyway. The macOS tables were identical for 27.2.
- **Resolving `hw=Automatic`** from the runtime's `InputMode_<lang>.plist`. It predicted German and Spanish – ISO but not the multilingual `es_419` mode, so the receipt reports it unresolved instead.
- **Setting the simulator's layout from Manzanero.** It works through `defaults` (and needs an app relaunch), but writes private preference keys of the simulated device; Manzanero only reads them. The verification set them by hand.
