import AppleDeviceBridge
import Foundation

/// Which devices a tunnel of the tool's own can be opened to right now, for
/// `devices`: the entries Apple's usbmuxd lists, by cable or by network
/// (docs/transport.md#a-tunnel-of-the-tools-own). A device that is not
/// listed, such as an Apple TV, which has no cable to be trusted over, is
/// reached over Apple's tunnel only.
enum DeviceTunnelLinks {
    /// UDID to "cable" or "network"; the cable wins when a device has both,
    /// as it does when the tunnel is opened. Asks the Mac's usbmuxd only.
    static func live() -> [String: String] {
        var links: [String: String] = [:]
        _ = ADCListDeviceTunnelLinks { udid, link in
            guard let udid else { return }
            let name = String(cString: udid)
            if link == 1 { links[name] = "cable" } else if links[name] == nil { links[name] = "network" }
        }
        return links
    }

    /// `devicectl`'s inventory with `ownTunnel` added to each physical
    /// device (`cable`, `network` or `unavailable`) and, at the top, the
    /// whole list under `ownTunnel`, which also names a device usbmuxd lists
    /// and `devicectl` does not. Returns the lines to print for a person.
    static func annotate(_ inventory: Data, links: [String: String]) throws -> (data: Data, summary: [String]) {
        guard var root = try JSONSerialization.jsonObject(with: inventory) as? [String: Any] else { return (inventory, []) }
        var result = root["result"] as? [String: Any] ?? [:]
        var names: [String: String] = [:]
        let devices = (result["devices"] as? [[String: Any]] ?? []).map { device -> [String: Any] in
            let hardware = device["hardwareProperties"] as? [String: Any]
            guard hardware?["reality"] as? String != "simulated", let udid = hardware?["udid"] as? String else { return device }
            if let name = (device["deviceProperties"] as? [String: Any])?["name"] as? String { names[udid] = name }
            var device = device
            device["ownTunnel"] = links[udid] ?? "unavailable"
            return device
        }
        if result["devices"] != nil { result["devices"] = devices }
        root["result"] = result
        let listed = links.keys.sorted { (names[$0] ?? $0) < (names[$1] ?? $1) }
        root["ownTunnel"] = ["source": "usbmuxd", "devices": listed.map { udid -> [String: Any] in
            var entry: [String: Any] = ["udid": udid, "link": links[udid] ?? ""]
            if let name = names[udid] { entry["name"] = name }
            return entry
        }] as [String: Any]
        var summary = ["", "The tool's own tunnel (devices Apple's usbmuxd lists now):"]
        summary += listed.isEmpty ? ["  none"] : listed.map { "  \(names[$0] ?? "\($0) (not in the list above)"): \(links[$0] ?? "")" }
        summary.append("  Every other device is reached over Apple's tunnel.")
        return (try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), summary)
    }
}
