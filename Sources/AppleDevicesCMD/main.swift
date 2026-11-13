import Foundation

let help = """
appledevicescmd — Apple device tools for terminals and agents

Usage:
  appledevicescmd mcp                  Serve MCP tools over stdio
  MCP stdin EOF and SIGINT/SIGTERM cancel owned tools and wait for cleanup; forced exit cannot guarantee release.
  appledevicescmd devices physical     List CoreDevice devices as JSON
  appledevicescmd devices simulators   List available simulators as JSON
  appledevicescmd pair wifi <host> <port> <new-record.pairing.plist>
  appledevicescmd --pairing-file <record> physical <UDID> <bridge-operation> ...
  appledevicescmd --physical-backend coredevice physical <device> <button|tap|multi-tap|long-press|gesture|drag|swipe|key|type|paste|multi-drag|pinch> ...
  appledevicescmd --physical-backend coredevice physical <device> gesture '<JSON with frames:[{ms,touches:[{id,x,y}]}]>'
  appledevicescmd --recording-backend coredevice physical <device> record <new.mp4> <seconds> [h264|hevc]
  appledevicescmd --physical-backend coredevice physical <device> long-press <x> <y> <seconds: 0.1...10>
  Native paste replaces the device clipboard with Unicode text, then pastes at the focused caret/selection.
  Buttons, tap, long-press, drag, swipe, pinch and two-path multi-drag call Apple CoreDevice in process.
  Named keys and paste keys call Apple CoreDevice in process; paste uses Apple's devicectl clipboard copy.
  Physical type sends 1...512 printable US-layout ASCII characters, tab or LF in process; no clipboard change.
  Gesture schedules, multi-tap and three-to-five-path multi-drag use in-process Universal HID.
  During direct physical input, SIGINT/SIGTERM cancels and attempts release, exiting 130/143.
  A second signal or a 30-second cleanup deadline forces exit; device-side release is unverified.
  Non-Apple device helper executables are disabled, including AXe, idevice, and ipb helpers.
  Pairing prompts for the device's PIN; use its advertised _remotepairing._tcp endpoint.
  appledevicescmd doctor               Check Xcode and device-service access
  appledevicescmd ocr <image-path>     Recognize image text and normalized bounds as JSON
  appledevicescmd physical <device> apps
  appledevicescmd physical <device> <processes|details>
  appledevicescmd physical <device> readiness   Report Developer Mode and developer-image status
  appledevicescmd <physical|simulator> <UDID> handoff <message> [terminal-timeout-seconds]
  Handoff asks for a human action on the device, then waits for explicit completion.
  appledevicescmd physical <device> reports [relative-directory]
  appledevicescmd physical <device> report <relative-report-path> <local-destination>
  appledevicescmd physical <UDID> logs <seconds: 1...30> [pid]
  appledevicescmd physical <device> terminate <pid>
  appledevicescmd physical <device> open-url <url>
  appledevicescmd physical <device> files <bundle-id> <relative-path>
  appledevicescmd physical <device> pull <bundle-id> <remote-path> <local-path>
  appledevicescmd physical <device> push <bundle-id> <local-path> <remote-path>
  App-data paths are relative to the app's container; report paths to systemCrashLogs.
  '.' means the selected domain's root. Reports are listed without recursion.
  appledevicescmd physical <device> <launch|uninstall> <bundle-id>
  appledevicescmd physical <device> install <app-path>
  appledevicescmd physical <device> screenshot <output.png>
  appledevicescmd <physical|simulator> <device> screen [auto|tree|ocr]
  Screen captures an image and selects accessibility/OCR with explicit fallback diagnostics.
  appledevicescmd <physical|simulator> <device> record <output.mp4> <seconds: 1...300> [h264|hevc]
  Recording refuses an existing destination; its parent directory must exist.
  appledevicescmd <physical|simulator> <UDID> build-run <project.xcodeproj|workspace.xcworkspace> <scheme>
      [--configuration <name>] [--app-target <name>]
  Build & Run targets iOS, defaults to Debug, and requires xcsift on PATH.
  appledevicescmd physical <UDID> hid-info
  appledevicescmd physical <UDID> ax-snapshot [new-local-archive.plist]  Experimental raw archive
  appledevicescmd physical <UDID> tree [positive-pid]  Default selects the app at display centre
  appledevicescmd physical <UDID> <press-id|press-label> [positive-pid] <exact-selector>
  appledevicescmd physical <UDID> <scroll-id|scroll-label> [positive-pid] <exact-selector>
  AX press resolves a fresh unique visible/enabled element; native acceptance does not verify UI effect.
  appledevicescmd decode-ax-archive <local-plist>  Offline structural archive inspection
  appledevicescmd physical <UDID> tap <x> <y>
  appledevicescmd physical <UDID> multi-tap <x1> <y1> <x2> <y2> [<x3> <y3> ...]
  appledevicescmd physical <UDID> multi-drag <seconds> <start-x> <start-y> <end-x> <end-y> ... (2...5 paths)
  appledevicescmd physical <UDID> pinch <center-x> <center-y> <start-span> <end-span> <seconds>
  appledevicescmd physical <UDID> <swipe|drag> <x1> <y1> <x2> <y2> <seconds>
  appledevicescmd physical <UDID> button <home|lock|volume-up|volume-down>
  appledevicescmd physical <UDID> key <return|escape|backspace|tab|space|up|down|left|right>
  appledevicescmd physical <UDID> type <text>   Experimental US-layout ASCII, 1...512 characters
  Physical ax-snapshot/tree/selector actions and logs are unavailable pending direct Apple replacements.
  Logs capture a finite experimental OS trace, capped at 2000 entries/4 MiB of entry JSON.
  Physical coordinates are normalized 0...1, with the origin at the top left.
  appledevicescmd simulator <device> <apps|boot|shutdown>
  appledevicescmd simulator <device> <launch|terminate|uninstall> <bundle-id>
  appledevicescmd simulator <device> install <app-path>
  appledevicescmd simulator <device> open-url <url>
  appledevicescmd simulator <device> screenshot <output.png>
  appledevicescmd simulator <UDID> tree
  appledevicescmd simulator <UDID> tap <x> <y>
  appledevicescmd simulator <UDID> <tap-id|tap-label> <selector>
  appledevicescmd simulator <UDID> <swipe|drag> <x1> <y1> <x2> <y2> <seconds>
  appledevicescmd simulator <UDID> type <text>
  appledevicescmd simulator <UDID> button <name>
  Simulator input and tree commands are unavailable pending direct Apple replacements.
  Prefix a planned command with --dry-run to print its invocation without executing.
  appledevicescmd --help
  appledevicescmd --version

Physical input is experimental; remaining parity work is tracked in docs/ROADMAP.md.
Physical single Xcode commands preserve devicectl JSON; readiness/build/record return CLI metadata.
Simulator app/lifecycle commands preserve simctl output; AXe tree/input commands return JSON.
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
    if args == ["--version"] { print("appledevicescmd 0.1.0-dev"); exit(0) }
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
