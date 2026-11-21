import Foundation
import VibeCore
import VibeNode

/// The typed word (the engine plan's EN-D5): every state-changing request asks, on the command line's controlling
/// terminal (`/dev/tty`), for a four-letter code printed with what the request will do. No controlling terminal:
/// refused, saying why, even with a terminal on stdin (a process `setsid` started, or given a pty it doesn't control),
/// since the server's weaker rule refuses a state change from a peer with no controlling terminal (S3) and the code
/// would be typed for nothing. A guard rail against a request run without the user's hands (an agent's Bash tool has
/// no terminal; `script` gives it one), not a lock.
enum TypedWord {
    /// What the command line says under the Mac's rule, in place of asking the code: the word the dialog will start with.
    static func approvalNote(_ word: String) -> String {
        "The Mac now asks for Touch ID or your login password. Its dialog starts with \(word): approve only a dialog that does "
            + "and names what is shown above. A dialog with another word isn't this request: cancel it."
    }

    /// What `refused` says for each outcome but `typed` (`TypedOutcome.refusal`, in `VibeNode` since the start plan's
    /// S2, so `StartSequence` takes the asker's answer).
    static func refusal(_ outcome: TypedOutcome) -> String { outcome.refusal }

    /// Shows `what` and `code` on the controlling terminal (`/dev/tty` alone) and reads one line there. Under the Mac's
    /// rule (`NodeClient.approvalRule`: the server asks Touch ID or the login password for each state change, its dialog
    /// naming what the server built of the request) it shows `what` and that the Mac will ask, and asks no code.
    /// `approval`: the request goes to a server on the Mac's rule (`NodeClient.approvalRule`), which asks the person at the
    /// Mac: `what` is shown with the word the dialog will start with (`word`, else `code`: `NodeIds.code(action:)` of the
    /// request's action id, which the server puts first in the dialog), and no code is asked.
    static func ask(approval: Bool = false, code: String, what: String, word: String? = nil) -> TypedOutcome {
        if approval {
            Say.err("\(what)\n\(approvalNote(word ?? code))")
            return .typed
        }
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
