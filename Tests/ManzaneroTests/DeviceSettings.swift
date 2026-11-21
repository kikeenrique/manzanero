import Foundation
import MCP
import Testing
@testable import Manzanero

struct DeviceSettingsTests {
    let simulator = "1DCC0F91-CF8C-4774-BD9C-BC94AF982632"
    let device = "00008110-000A11112222801E"

    func arguments(_ cli: [String]) throws -> [String] {
        guard case .tool(let tool) = try request(cli) else { Issue.record("\(cli[0]) is not a tool request"); return [] }
        return tool.command.arguments
    }

    @Test func everySettingPlansTheSameDevicectlCallOnBothPlatforms() throws {
        let tail = ["--timeout", "30", "--json-output", "-"]
        for (target, id) in [("--device", device), ("--simulator", simulator)] {
            #expect(try arguments(["rotate", "landscape-left", target, id])
                == ["devicectl", "device", "orientation", "set", "landscapeLeft", "--device", id] + tail)
            #expect(try arguments(["settings", "--appearance", "dark", "--text-size", "accessibility-large", target, id])
                == ["devicectl", "device", "settings", "appearance", "--mode", "dark", "--text-size", "accessibility-large",
                    "--larger-accessibility-sizes", "on", "--device", id] + tail)
            #expect(try arguments(["location", target, id, "--", "-33.8688,151.2093"])
                == ["devicectl", "device", "simulate", "location", "coordinate", "--latitude=-33.8688", "--longitude=151.2093", "--device", id] + tail)
            #expect(try arguments(["location", "--clear", target, id]) == ["devicectl", "device", "simulate", "location", "clear", "--device", id] + tail)
            #expect(try arguments(["status-bar", "--time", "9:41", "--wifi-bars", "3", "--battery-level", "100", target, id])
                == ["devicectl", "device", "simulate", "statusBar", "override", "--time=9:41", "--battery-level=100",
                    "--wifi-mode", "active", "--wifi-strength", "3", "--device", id] + tail)
            #expect(try arguments(["status-bar", "--clear", target, id]) == ["devicectl", "device", "simulate", "statusBar", "clear", "--device", id] + tail)
            #expect(try arguments(["clipboard", target, id])
                == ["devicectl", "device", "pasteboard", "paste", "--device", id, "--timeout", "30", "--json-output", DeviceSettings.resultPlaceholder])
        }
    }

    @Test(arguments: [["rotate", "sideways"], ["settings"], ["settings", "--appearance", "blue"], ["settings", "--text-size", "huge"],
                      ["location", "91,0"], ["location", "1"], ["location", "a,b"], ["location"], ["location", "1,2", "--clear"],
                      ["status-bar"], ["status-bar", "--wifi-bars", "4"], ["status-bar", "--battery-level", "101"],
                      ["status-bar", "--time", "9:41", "--clear"], ["status-bar", "--data-network", "6G"]])
    func invalidSettingsAreUsageErrorsBeforeAnyDevice(_ cli: [String]) {
        #expect(throws: (any Error).self) { try request(cli + ["--simulator", simulator]) }
    }

    @Test func clipboardIsReadOnlyAndTheOthersAreNot() throws {
        #expect(try request(["clipboard", "--simulator", simulator]).isReadOnly)
        for cli in [["rotate", "portrait"], ["settings", "--appearance", "dark"], ["location", "--clear"], ["status-bar", "--clear"]] {
            let readOnly = try request(cli + ["--device", device]).isReadOnly
            #expect(!readOnly)
        }
    }

    @Test func clipboardResultsKeepTextTypeAndEmptiness() throws {
        func result(_ fields: String) -> Data { Data(#"{"info":{"outcome":"success"},"result":{\#(fields)}}"#.utf8) }
        let text = try DeviceSettings.clipboardResult(stdout: Data("hola café".utf8),
                                                      resultFile: result(#""contentSize":10,"contentType":"public.utf8-plain-text""#))
        #expect(text["text"] as? String == "hola café" && text["empty"] as? Bool == false && text["bytes"] as? Int == 10)
        let empty = try DeviceSettings.clipboardResult(stdout: Data("Pasteboard is empty.\n".utf8), resultFile: result(#""pasteboardName":"general""#))
        #expect(empty["empty"] as? Bool == true && empty["text"] == nil)
        #expect(throws: CommandFailure.self) { try DeviceSettings.clipboardResult(stdout: Data(), resultFile: Data("{}".utf8)) }
    }

    @Test func doubleTapIsTwoTapsOfOneGestureSequence() throws {
        let input = try #require(try physicalInput(["double-tap", "0.25", "0.75", "--device", device]))
        #expect(input.operation == "gesture")
        let sequence = try #require(try JSONSerialization.jsonObject(with: Data(input.operands[0].utf8)) as? [String: Any])
        let frames = try #require(sequence["frames"] as? [[String: Any]])
        #expect(frames.map { $0["ms"] as? Int } == [0, 60, 160, 220])
        #expect(frames.map { ($0["touches"] as? [Any])?.count } == [1, 0, 1, 0])
        #expect(throws: (any Error).self) { try request(["double-tap", "1.5", "0.5", "--device", device]) }
        let tool = try #require(MCPTools.definitions.first { $0.name == "double_tap" })
        #expect(try tool.command(["platform": "simulator", "device": .string(simulator), "x": 0.5, "y": 0.5]) == ["double-tap", "--simulator=\(simulator)", "--", "0.5", "0.5"])
    }

    @Test func mcpToolsRouteToTheSameCommands() throws {
        let settings = try #require(MCPTools.definitions.first { $0.name == "device_settings" })
        let base: [String: Value] = ["platform": "simulator", "device": .string(simulator)]
        #expect(try settings.command(base.merging(["operation": "rotate", "orientation": "landscape-right"]) { $1 })
            == ["rotate", "--simulator=\(simulator)", "--", "landscape-right"])
        let located = try settings.command(base.merging(["operation": "location", "latitude": -33.8688, "longitude": 151.2093]) { $1 })
        #expect(located == ["location", "--simulator=\(simulator)", "--", "-33.8688,151.2093"])
        #expect(try arguments(located).contains("--latitude=-33.8688"))
        let bar = try settings.command(base.merging(["operation": "status-bar", "time": "9:41", "wifi_bars": 2]) { $1 })
        #expect(try arguments(bar).contains("--wifi-strength"))
        #expect(try settings.command(base.merging(["operation": "settings", "appearance": "dark"]) { $1 })
            == ["settings", "--simulator=\(simulator)", "--appearance=dark"])
        let clipboard = try #require(MCPTools.definitions.first { $0.name == "read_clipboard" })
        #expect(clipboard.readOnly)
        #expect(try clipboard.command(base) == ["clipboard", "--simulator=\(simulator)"])
    }
}
