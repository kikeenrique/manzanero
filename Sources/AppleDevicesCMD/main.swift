import Foundation

let help = """
appledevicescmd — Apple device tools for terminals and agents

Usage:
  appledevicescmd mcp                  Serve MCP tools over stdio
  appledevicescmd devices physical     List CoreDevice devices as JSON
  appledevicescmd devices simulators   List available simulators as JSON
  appledevicescmd pair wifi <host> <port> <new-record.pairing.plist>
  appledevicescmd --pairing-file <record> physical <UDID> <bridge-operation> ...
  Pairing prompts for the device's PIN; use its advertised _remotepairing._tcp endpoint.
  appledevicescmd doctor               Check Xcode and device-service access
  appledevicescmd ocr <image-path>     Recognize image text and normalized bounds as JSON
  appledevicescmd physical <device> apps
  appledevicescmd physical <device> <processes|details>
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
  appledevicescmd <physical|simulator> <UDID> build-run <project.xcodeproj|workspace.xcworkspace> <scheme>
      [--configuration <name>] [--app-target <name>]
  Build & Run targets iOS, defaults to Debug, and requires xcsift on PATH.
  appledevicescmd physical <UDID> hid-info
  appledevicescmd physical <UDID> ax-snapshot  Experimental raw accessibility archive
  appledevicescmd physical <UDID> tap <x> <y>
  appledevicescmd physical <UDID> multi-tap <x1> <y1> <x2> <y2> [<x3> <y3> ...]
  appledevicescmd physical <UDID> <swipe|drag> <x1> <y1> <x2> <y2> <seconds>
  appledevicescmd physical <UDID> button <home|lock|volume-up|volume-down>
  appledevicescmd physical <UDID> key <return|escape|backspace|tab|space|up|down|left|right>
  Physical input, ax-snapshot, and logs require the optional appledevices-idevice bridge on PATH.
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
  Simulator input and tree commands require AXe on PATH and an explicit UDID.
  Prefix a planned command with --dry-run to print its invocation without executing.
  appledevicescmd --help
  appledevicescmd --version

Physical input is experimental; remaining parity work is tracked in docs/ROADMAP.md.
Physical Xcode commands return devicectl JSON; bridge commands return bridge JSON.
Simulator app/lifecycle commands preserve simctl output; AXe tree/input commands return JSON.
Temporary process output is created beneath ./tmp and normally cleaned up on exit.
"""

do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["mcp"] {
        try await AppleMCPServer.run()
        exit(0)
    }
    if args.isEmpty || args == ["--help"] || args == ["-h"] { print(help); exit(0) }
    if args == ["--version"] { print("appledevicescmd 0.1.0-dev"); exit(0) }
    let dryRun = args.first == "--dry-run"
    if dryRun { args.removeFirst() }
    let result = try await CommandService().execute(args, dryRun: dryRun, allowInteractive: true)
    FileHandle.standardOutput.write(result.data)
    if result.data.last != 10 { print() }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
