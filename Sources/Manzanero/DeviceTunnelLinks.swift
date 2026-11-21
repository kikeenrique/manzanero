import AppleDeviceBridge
import Foundation

/// Which devices a tunnel of the tool's own can be opened to right now, for
/// `devices`: the entries Apple's usbmuxd lists, by cable or by network
/// (docs/transport.md#a-tunnel-of-the-tools-own), and the devices the tool
/// has a pairing of its own with (`manzanero pair`, an Apple TV), which
/// usbmuxd never lists. Any other device is reached over Apple's tunnel.
enum DeviceTunnelLinks {
    /// UDID to "cable", "network" or "paired". The cable wins when a device
    /// has both, and usbmuxd wins over a pairing, as they do when the tunnel
    /// is opened (`DeviceTunnelPool.openByTrustOrPairing`). Asks the Mac's
    /// usbmuxd and reads the names of the pairing files; no device is
    /// contacted and no key is read.
    static func live() -> [String: String] {
        var links: [String: String] = [:]
        _ = ADCListDeviceTunnelLinks { udid, link in
            guard let udid else { return }
            let name = String(cString: udid)
            if link == 1 { links[name] = "cable" } else if links[name] == nil { links[name] = "network" }
        }
        return merging(links, paired: paired())
    }

    /// The UDIDs the tool holds a pairing for: the names of the files under
    /// `PairingIdentity.directory`, one per device.
    static func paired(directory: URL = PairingIdentity.directory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.filter { !$0.isEmpty }.sorted()
    }

    /// usbmuxd's links, with "paired" for a paired device it does not list.
    static func merging(_ links: [String: String], paired: [String]) -> [String: String] {
        var links = links
        for udid in paired where links[udid] == nil { links[udid] = "paired" }
        return links
    }

    /// `devicectl`'s inventory with `ownTunnel` added to each physical
    /// device (`cable`, `network`, `paired` or `unavailable`) and, at the
    /// top, the whole list under `ownTunnel`, which also names a device
    /// usbmuxd lists, or the tool is paired with, and `devicectl` does not.
    /// Returns the lines to print for a person.
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
        root["ownTunnel"] = ["source": "usbmuxd and the tool's pairings", "devices": listed.map { udid -> [String: Any] in
            var entry: [String: Any] = ["udid": udid, "link": links[udid] ?? ""]
            if let name = names[udid] { entry["name"] = name }
            return entry
        }] as [String: Any]
        var summary = ["", "The tool's own tunnel (devices Apple's usbmuxd lists now, and devices paired with manzanero pair):"]
        summary += listed.isEmpty ? ["  none"] : listed.map { "  \(names[$0] ?? "\($0) (not in the list above)"): \(links[$0] ?? "")" }
        summary.append("  An iPhone or iPad not listed is reached over Apple's tunnel; an Apple TV not listed needs manzanero pair for accessibility.")
        return (try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), summary)
    }
}
