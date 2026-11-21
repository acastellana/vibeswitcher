import Foundation
import VibeCore

/// A session's dev servers (the app's dev pages, `Sources/VibeCore/DevPages.swift`, which offers the phone the
/// localhost pages Chrome has open; a node has no Chrome): the TCP ports a session's own processes listen on, from the
/// kernel's tables (`/proc/net/tcp`, `/proc/net/tcp6`: state LISTEN) and each process's descriptors (`/proc/<pid>/fd`:
/// `socket:[inode]`), for the session's program and what it started. Reads only, of the uid's own processes; nothing
/// is connected to, proxied or opened. As the app's: only an unprivileged port (1024 and up), never the node's own
/// (`NodeWeb.port`), and only one bound to this machine's loopback or to every address (a page there is
/// `http://localhost:PORT/`).
public enum DevPorts {
    public struct Listener: Equatable, Sendable {
        public var port: Int
        /// As the kernel's table has it: `127.0.0.1`, `0.0.0.0`, `::1` or `::`.
        public var address: String
        public var pid: Int32
        /// The program's name (its executable's last part), when it can be read.
        public var program: String?

        /// What a browser on this machine opens.
        public var url: String { "http://localhost:\(port)/" }
    }

    /// One listening socket of a table: its inode, address and port.
    struct Bound: Equatable {
        var inode: UInt64
        var address: String
        var port: Int
    }

    /// The listening sockets of `/proc/net/tcp` (`v6`: tcp6) text, loopback or every address only.
    static func listening(table: String, v6: Bool) -> [Bound] {
        table.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 9, fields[3] == "0A" else { return nil }
            let local = fields[1].split(separator: ":")
            guard local.count == 2, let port = Int(local[1], radix: 16), let inode = UInt64(fields[9]), inode > 0 else { return nil }
            guard let address = v6 ? address6(String(local[0])) : address4(String(local[0])) else { return nil }
            return Bound(inode: inode, address: address, port: port)
        }
    }

    /// The table's IPv4 address (8 hex digits, the host's byte order: little-endian) when it is loopback or any.
    static func address4(_ hex: String) -> String? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let bytes = [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, value >> 24]
        if bytes == [0, 0, 0, 0] { return "0.0.0.0" }
        return bytes[0] == 127 ? bytes.map(String.init).joined(separator: ".") : nil
    }

    /// The table's IPv6 address (32 hex digits) when it is `::`, `::1` or a v4-mapped loopback.
    static func address6(_ hex: String) -> String? {
        switch hex.uppercased() {
        case "00000000000000000000000000000000": return "::"
        case "00000000000000000000000001000000": return "::1"
        default:
            // ::ffff:127.x.x.x: the last word 127.x in the host's order, after 0000FFFF.
            let upper = hex.uppercased()
            guard upper.count == 32, upper.hasPrefix("0000000000000000FFFF0000"), let v4 = address4(String(upper.suffix(8))), v4 != "0.0.0.0" else { return nil }
            return v4
        }
    }

    /// The socket inodes `pid` holds (its descriptors that are `socket:[N]`).
    static func sockets(of pid: Int32, proc: String) -> Set<UInt64> {
        let folder = "\(proc)/\(pid)/fd"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var found: Set<UInt64> = []
        for name in names {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(folder)/\(name)"),
                  target.hasPrefix("socket:["), target.hasSuffix("]"), let inode = UInt64(target.dropFirst(8).dropLast()) else { continue }
            found.insert(inode)
        }
        return found
    }

    /// The ports `pids` listen on, by port, the first process holding each (`proc`: the proc folder, a test's own).
    public static func listening(pids: [Int32], proc: String = "/proc", program: (Int32) -> String? = { Platform.Processes.executable($0).map { ($0 as NSString).lastPathComponent } }) -> [Listener] {
        func read(_ name: String) -> String { (try? String(contentsOfFile: "\(proc)/net/\(name)", encoding: .utf8)) ?? "" }
        let bound = listening(table: read("tcp"), v6: false) + listening(table: read("tcp6"), v6: true)
        guard !bound.isEmpty else { return [] }
        let byInode = Dictionary(bound.map { ($0.inode, $0) }) { first, _ in first }
        var found: [Int: Listener] = [:]
        for pid in pids {
            for inode in sockets(of: pid, proc: proc) {
                guard let socket = byInode[inode], socket.port >= 1024, socket.port != Int(NodeWeb.port), found[socket.port] == nil else { continue }
                found[socket.port] = Listener(port: socket.port, address: socket.address, pid: pid, program: program(pid))
            }
        }
        return found.values.sorted { $0.port < $1.port }
    }

    /// A session's processes: its program and everything it started that runs now.
    public static func processes(of pid: Int32) -> [Int32] {
        [pid] + SessionStrays.descendants(of: pid).map(\.pid)
    }

    /// `session.ports`' result.
    public static func value(_ listeners: [Listener]) -> NodeWire.Value {
        .object(["ports": .array(listeners.map { listener in
            .object(["port": .int(listener.port), "address": .string(listener.address), "pid": .int(Int(listener.pid)),
                     "program": listener.program.map { .string(ConfigSeal.inert($0, limit: 80)) } ?? .null, "url": .string(listener.url)])
        })])
    }
}
