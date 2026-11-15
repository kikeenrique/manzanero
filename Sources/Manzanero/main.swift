import Foundation

let help = """
manzanero — Apple device tools for terminals and agents

Usage:
  manzanero mcp                  Serve MCP tools over stdio
  MCP stdin EOF and SIGINT/SIGTERM cancel owned tools and wait for cleanup; forced exit cannot guarantee release.
  manzanero devices physical     List CoreDevice devices as JSON
  manzanero devices simulators   List available simulators as JSON
  manzanero --physical-backend coredevice physical <device> <button|tap|multi-tap|long-press|gesture|drag|swipe|key|type|paste|multi-drag|pinch> ...
  manzanero --physical-backend coredevice physical <device> gesture '<JSON with frames:[{ms,touches:[{id,x,y}]}]>'
  manzanero --recording-backend coredevice physical <device> record <new.mp4> <seconds> [h264|hevc]
  manzanero --physical-backend coredevice physical <device> long-press <x> <y> <seconds: 0.1...10>
  manzanero --physical-backend coredevice physical <device> tree [positive-pid]
  Physical AX trees and exact selector actions use native Apple interfaces; inspect fresh state after actions.
  Native paste replaces the device clipboard with Unicode text, then pastes at the focused caret/selection.
  Buttons, tap, long-press, drag, swipe, pinch and two-path multi-drag call Apple CoreDevice in process.
  Named keys and paste keys call Apple CoreDevice in process; paste uses Apple's devicectl clipboard copy.
  Physical type sends 1...512 printable US-layout ASCII characters, tab or LF in process; no clipboard change.
  Gesture schedules, multi-tap and three-to-five-path multi-drag use in-process Universal HID.
  During direct physical input, SIGINT/SIGTERM cancels and attempts release, exiting 130/143.
  A second signal or a 30-second cleanup deadline forces exit; device-side release is unverified.
  coredevice is the only physical backend and the default, so --physical-backend coredevice may be omitted.
  manzanero doctor               Check Xcode and device-service access, host versions, and host-only
                                 availability of each private Apple interface by capability (no device contact)
  manzanero ocr <image-path>     Recognize image text and normalized bounds as JSON
  manzanero physical <device> apps
  manzanero physical <device> <processes|details>
  manzanero physical <device> readiness   CoreDevice prerequisites plus separate display/passcode observations
  Readiness does not verify UI Automation or prove current UI unlock.
  manzanero physical <device> media-status   Read native media support/status; no stream start/stop
  manzanero <physical|simulator> <UDID> handoff <message> [terminal-timeout-seconds]
  Handoff asks for a human action on the device, then waits for explicit completion.
  manzanero physical <device> reports [relative-directory]
  manzanero physical <device> report <relative-report-path> <local-destination>
  manzanero physical <device> terminate <pid>
  manzanero physical <device> open-url <url>
  manzanero physical <device> files <bundle-id> <relative-path>
  manzanero physical <device> pull <bundle-id> <remote-path> <local-path>
  manzanero physical <device> push <bundle-id> <local-path> <remote-path>
  App-data paths are relative to the app's container; report paths to systemCrashLogs.
  '.' means the selected domain's root. Reports are listed without recursion.
  manzanero physical <device> <launch|uninstall> <bundle-id>
  manzanero physical <device> install <app-path>
  manzanero physical <device> screenshot <output.png>
  manzanero <physical|simulator> <device> screen [auto|tree|ocr]
  Screen captures an image and selects accessibility/OCR with explicit fallback diagnostics.
  manzanero <physical|simulator> <device> record <output.mp4> <seconds: 1...300> [h264|hevc]
  Recording refuses an existing destination; its parent directory must exist.
  manzanero <physical|simulator> <UDID> build-run <project.xcodeproj|workspace.xcworkspace> <scheme>
      [--configuration <name>] [--app-target <name>] [--allow-provisioning-updates [--allow-device-registration]]
  Build & Run targets iOS, defaults to Debug, and requires xcsift on PATH.
  Physical builds use signing assets already on the Mac. --allow-provisioning-updates lets Xcode use the
  account in Xcode's settings to create or change certificates, app IDs and profiles on Apple's developer
  services; --allow-device-registration also registers the device with the team. Physical only; off by default.
  manzanero physical <UDID> tree [positive-pid]  Native AX; omitted PID selects primary portrait display-centre app
  manzanero physical <UDID> <press-id|press-label> [positive-pid] <exact-selector>
  manzanero physical <UDID> <scroll-id|scroll-label> [positive-pid] <exact-selector>
  AX press resolves a fresh unique visible/enabled element; native acceptance does not verify UI effect.
  manzanero physical <UDID> <wait-id|wait-label> [positive-pid] <exact-selector>
      [--until visible|gone|enabled|disabled|value] [--value <exact-text>]
      [--timeout <seconds: 0...60, default 10>] [--interval <seconds: 0.25...5, default 0.5>]
  AX wait polls one session read-only until the condition holds: visible (default) needs exactly one
  visible match; gone means no match or none visible. Omitted PID re-selects the display-centre app
  each poll. Exit 0 when met, 124 on timeout (JSON on stdout either way), 1 on failure. No input sent.
  Options follow the selector; with a PID, the selector cannot be one of the option names.
  manzanero decode-ax-archive <local-plist>  Offline structural archive inspection
  manzanero physical <UDID> tap <x> <y>
  manzanero physical <UDID> multi-tap <x1> <y1> <x2> <y2> [<x3> <y3> ...]
  manzanero physical <UDID> multi-drag <seconds> <start-x> <start-y> <end-x> <end-y> ... (2...5 paths)
  manzanero physical <UDID> pinch <center-x> <center-y> <start-span> <end-span> <seconds>
  manzanero physical <UDID> <swipe|drag> <x1> <y1> <x2> <y2> <seconds>
  manzanero physical <UDID> button <home|lock|volume-up|volume-down>
  manzanero physical <UDID> key <return|escape|backspace|tab|space|up|down|left|right>
  manzanero physical <UDID> type <text>   Experimental US-layout ASCII, 1...512 characters
  Physical coordinates are normalized 0...1, with the origin at the top left.
  manzanero simulator <device> <apps|boot|shutdown>
  manzanero simulator <device> <launch|terminate|uninstall> <bundle-id>
  manzanero simulator <device> install <app-path>
  manzanero simulator <device> open-url <url>
  manzanero simulator <device> screenshot <output.png>
  Simulator input (tap, swipe, type, button) and accessibility hierarchy (tree) are not available yet;
  simulator screen uses OCR.
  Prefix a planned command with --dry-run to print its invocation without executing.
  manzanero --help
  manzanero --version

Physical input is experimental; remaining work is tracked in docs/roadmap.md.
Physical single Xcode commands preserve devicectl JSON; readiness/build/record return CLI metadata.
Simulator app/lifecycle commands preserve simctl output; simulator input and hierarchy are currently unavailable.
Temporary process output is created beneath ./tmp and normally cleaned up on exit.
"""

do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["mcp"] {
        let result = try await CLIInputSignals.run(context: "MCP server") {
            try await AppleMCPServer.run()
            return CommandOutput(data: Data())
        }
        exit(result.exitCode)
    }
    if args.isEmpty || args == ["--help"] || args == ["-h"] { print(help); exit(0) }
    if args == ["--version"] { print("manzanero \(manzaneroVersion)"); exit(0) }
    let dryRun = args.first == "--dry-run"
    if dryRun { args.removeFirst() }
    let commandArgs = args
    let result: CommandOutput
    if CLIInputSignals.applies(to: commandArgs, dryRun: dryRun) {
        result = try await CLIInputSignals.run {
            try await CommandService().execute(commandArgs, allowInteractive: true)
        }
    } else {
        result = try await CommandService().execute(commandArgs, dryRun: dryRun, allowInteractive: true)
    }
    if result.data.isEmpty, result.exitCode != 0 { exit(result.exitCode) }
    FileHandle.standardOutput.write(result.data)
    if result.data.last != 10 { print() }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
