import Foundation
import VibeCore

/// `vibeswitcher plugin list`'s lines (`plugin.list`'s result): each plugin, on or off (and whether that's the user's
/// setting or its default), why it can't run here, and what it adds.
public enum PluginListText {
    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "", limit: 400) }

    public static func lines(_ plugins: [NodeWire.Value]) -> [String] {
        guard !plugins.isEmpty else { return ["no feature plugins in this build"] }
        var lines: [String] = []
        for plugin in plugins {
            let id = inert(plugin["id"]?.string)
            let on = plugin["on"]?.bool == true
            var state = on ? "on" : "off"
            if plugin["known"]?.bool != true {
                state = "off until the session host's vault says (try again in a moment)"
            } else if let why = plugin["unavailable"]?.string {
                state = "off: can't run on this node: " + inert(why)
            } else if let since = plugin["defaultSince"]?.string {
                state += " (at its default since the session host's vault began, \(inert(since)): a host restart starts it over; "
                    + "`vibeswitcher plugin \(on ? "off" : "on") \(id)` changes it)"
            } else if plugin["set"]?.bool == plugin["defaultOn"]?.bool {
                state += " (its default)"
            }
            lines.append("\(id)  \(inert(plugin["title"]?.string))  \(state)")
            lines.append("  " + inert(plugin["summary"]?.string))
            for command in plugin["commands"]?.array ?? [] {
                lines.append("  adds for agents: \(inert(command["name"]?.string)): \(inert(command["about"]?.string))")
            }
            let tools = (plugin["tools"]?.array ?? []).compactMap(\.string)
            if !tools.isEmpty { lines.append("  MCP tools: " + tools.map(inert).joined(separator: ", ")) }
            let settings = (plugin["settings"]?.array ?? []).compactMap(\.string)
            if !settings.isEmpty { lines.append("  settings: " + settings.map(inert).joined(separator: ", ")) }
            lines.append(on ? "  `vibeswitcher plugin off \(id)` turns it off" : "  `vibeswitcher plugin on \(id)` turns it on")
        }
        return lines
    }
}
