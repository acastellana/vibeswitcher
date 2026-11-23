import Foundation

/// The core's one command for any external plugin's request: `vs-ask ID -- WORDS…` (Resources/bin/vs-ask, through the
/// node's tool server's filing mode; the definitions's "External plugins": "Filing"). It asks the session host which of
/// its sessions this process runs in, asks the node's server (`plugin.file`) for the request's bytes, which the server
/// has the plugin's `file` make from these words (or refuse, said at once), has the session host stamp those bytes for
/// this session (the host stamps only for the caller's own session, whatever the server was told), and files them, the
/// stamp first, in `<root>/plugin-requests/<ID>/`. The plugin never writes a request, and the node draws only what the
/// host stamped.
public enum PluginAsk {
    public static let usage = """
        usage: vs-ask PLUGIN -- WORDS…

        Asks an external plugin of VibeSwitcher's (vibeswitcher plugin list shows them) for something the user decides:
        its card waits in VibeSwitcher, and nothing happens until the user answers it in their own terminal. What
        happens comes back to this session as a message. Exit status: 0 filed, 1 refused, 2 usage.
        """

    public struct Refusal: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The folder a plugin's requests are filed in.
    public static func folder(_ plugin: String, root: URL = VibePaths.root) -> URL {
        root.appendingPathComponent("plugin-requests/\(plugin)", isDirectory: true)
    }

    /// `vs-ask …` as the tool server runs it: what to print and the exit status. `ask`: the node's server's
    /// `plugin.file` (a JSON request's args in, its result or why not out).
    public static func run(_ arguments: [String], cwd: String, vault: LeadVault, root: URL = VibePaths.root,
                           ask: ([String: Any]) -> Result<[String: Any], Refusal> = askServer)
        -> (status: Int32, output: String, error: String) {
        guard let plugin = arguments.first, !["help", "--help", "-h"].contains(plugin) else {
            return arguments.isEmpty ? (2, "", usage) : (0, usage, "")
        }
        guard arguments.count >= 3, arguments[1] == "--", LeadVaultV2.pluginID(plugin) else { return (2, "", usage) }
        let words = Array(arguments.dropFirst(2))
        if let refusal = PluginGate.refusal(plugin, command: "vs-ask \(plugin)", at: root.appendingPathComponent("plugins.json")) { return (1, "", refusal) }
        do {
            let session: String
            do { session = try vault.walletSession() } catch {
                throw Refusal("VibeSwitcher's session host didn't say which of its sessions this process runs in (\(error)): "
                              + "run it from the agent's own session in VibeSwitcher, with VibeSwitcher running")
            }
            let result: [String: Any]
            switch ask(["plugin": plugin, "session": session.lowercased(), "words": words, "cwd": cwd]) {
            case .failure(let why): throw why
            case .success(let answer): result = answer
            }
            guard let encoded = result["request"] as? String, let bytes = Data(base64Encoded: encoded), let id = result["id"] as? String,
                  WalletRequestFormat.isID(id) else { throw Refusal("VibeSwitcher's server answered something else") }
            let digest = WalletStamp.digest(bytes)
            let seal: String
            do { seal = try vault.sealWallet(session: session.lowercased(), digest: digest) } catch {
                throw Refusal("VibeSwitcher's session host didn't stamp the request (\(error))")
            }
            let into = folder(plugin, root: root)
            try VibePaths.ensurePrivate(into)
            try VibePaths.writePrivate(JSONEncoder().encode(WalletStamp(session: session.lowercased(), digest: digest, seal: seal)),
                                       to: into.appendingPathComponent("\(id).seal"))
            try VibePaths.writePrivate(bytes, to: into.appendingPathComponent("\(id).json"))
            let title = (result["title"] as? String).map { ConfigSeal.inert($0, limit: 60) } ?? plugin
            return (0, "Filed \(title) request \(id): its card waits in VibeSwitcher, and nothing happens until the user answers it in their "
                       + "terminal. What happens will come to this session as a message; don't file it again.", "")
        } catch let refusal as Refusal {
            return (1, "", "vs-ask \(plugin): refused: \(refusal.description)")
        } catch {
            return (1, "", "vs-ask \(plugin): refused: \(error)")
        }
    }

    /// The node's server's `plugin.file` with `args`, over its socket (`<root>/v2/server.sock`): one JSON request, its
    /// one reply. Blocks, 30 s at most.
    public static func askServer(_ args: [String: Any]) -> Result<[String: Any], Refusal> {
        let path = VibePaths.root.appendingPathComponent("v2/server.sock").path
        guard var address = Platform.Sockets.unixAddress(path) else { return .failure(Refusal("VibeSwitcher's server socket isn't there")) }
        let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
        guard fd >= 0 else { return .failure(Refusal("no socket (errno \(errno))")) }
        defer { Sys.close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(Refusal("VibeSwitcher's server isn't running (errno \(errno))")) }
        var buffer = Data()
        func line() -> [String: Any]? {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while !buffer.contains(UInt8(ascii: "\n")) {
                let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
                guard count > 0, buffer.count < 1 << 20 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
            let end = buffer.firstIndex(of: UInt8(ascii: "\n"))!
            let text = buffer[buffer.startIndex..<end]
            buffer = Data(buffer[(end + 1)...])
            return try? JSONSerialization.jsonObject(with: text) as? [String: Any]
        }
        guard line()?["kind"] as? String == "hello" else { return .failure(Refusal("VibeSwitcher's server didn't say hello")) }
        let id = UUID().uuidString.lowercased()
        guard let request = try? JSONSerialization.data(withJSONObject: ["v": 1, "id": id, "kind": "plugin.file", "args": args]) else {
            return .failure(Refusal("the request didn't encode"))
        }
        let bytes = request + Data("\n".utf8)
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
        guard sent == bytes.count else { return .failure(Refusal("the request wasn't sent")) }
        while let reply = line() {
            guard reply["re"] as? String == id else { continue }
            if reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] { return .success(result) }
            let message = (reply["error"] as? [String: Any])?["message"] as? String ?? "refused"
            return .failure(Refusal(ConfigSeal.inert(message, limit: 600)))
        }
        return .failure(Refusal("VibeSwitcher's server didn't answer"))
    }
}
