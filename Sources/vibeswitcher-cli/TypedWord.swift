import Foundation
import VibeCore

/// The typed word (the engine plan's EN-D5): every state-changing request asks, on the command line's controlling
/// terminal (`/dev/tty`), for a four-letter code printed with what the request will do. No controlling terminal:
/// refused, saying why, even with a terminal on stdin (a process `setsid` started, or given a pty it doesn't control),
/// since the server's weaker rule refuses a state change from a peer with no controlling terminal (S3) and the code
/// would be typed for nothing. A guard rail against a request run without the user's hands (an agent's Bash tool has
/// no terminal; `script` gives it one), not a lock.
enum TypedWord {
    enum Outcome: Equatable {
        case typed
        case wrong
        case noTerminal
    }

    /// What `refused` says for each outcome but `typed`.
    static func refusal(_ outcome: Outcome) -> String {
        switch outcome {
        case .typed: return ""
        case .wrong: return "the code typed isn't the one shown: nothing was done"
        case .noTerminal: return "this needs a code typed on a terminal (this process has no controlling terminal: /dev/tty can't be opened): nothing was done"
        }
    }

    /// Shows `what` and `code` on the controlling terminal (`/dev/tty` alone) and reads one line there.
    static func ask(code: String, what: String) -> Outcome {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return .noTerminal }
        defer { Sys.close(fd) }
        let prompt = "\(what)\nType \(code) and Enter to go on (anything else stops): "
        _ = prompt.withCString { Sys.write(fd, $0, strlen($0)) }
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let got = Sys.read(fd, &byte, 1)
            if got < 0, errno == EINTR { continue }
            guard got == 1 else { break }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            line.append(byte)
            if line.count > 64 { break }
        }
        let typed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
        return typed == code ? .typed : .wrong
    }
}
