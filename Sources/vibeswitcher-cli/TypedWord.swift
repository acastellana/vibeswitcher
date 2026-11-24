import Foundation
import VibeCore
import VibeNode

/// The typed word (the engine plan's EN-D5): every state-changing request asks, on the command line's controlling
/// terminal (`/dev/tty`), for a four-letter code printed with what the request will do. No controlling terminal:
/// refused, saying why, even with a terminal on stdin (a process `setsid` started, or given a pty it doesn't control),
/// since the server's weaker rule refuses a state change from a peer with no controlling terminal (S3) and the code
/// would be typed for nothing. A guard rail against a request run without the user's hands (an agent's Bash tool has
/// no terminal; `script` gives it one), not a lock.
/// What only `TypedWord.said` makes, once its prompt was answered (the code typed, or, under the Mac's rule, what the
/// request does shown with the dialog's word): the words it showed. `NodeClient.change`, the one way a state change is
/// sent, takes it, and sends only an action whose word (`NodeIds.code(action:)`) it showed, so no command can send a
/// state change without the prompt (the architecture review's row 5, 2026-11-22). A guard rail, as the prompt is: the
/// server checks the terminal and the vault records the action either way.
struct Typed: Sendable {
    /// The codes the prompt showed: the one typed (the action's, a card's or a batch's) and the word the Mac's dialog
    /// starts with.
    fileprivate let words: Set<String>

    fileprivate init(words: Set<String>) { self.words = words }

    /// Whether the prompt showed `action`'s word, so `action` may go out as the request it named.
    func vouches(for action: String) -> Bool { words.contains(NodeIds.code(action: action)) }
}

/// The prompt answered otherwise than with the code (`TypedOutcome`'s other outcomes): what the command says, refused.
struct NotTyped: Error {
    let outcome: TypedOutcome
    var refusal: String { outcome.refusal }
}

enum TypedWord {
    /// Asks as `ask` does, for `action` (its code, `NodeIds.code(action:)`, unless `code` names another: a card's or a
    /// batch's, the action's then the Mac's dialog's `word`), and gives the token `NodeClient.change` takes.
    static func said(approval: Bool, action: String, code: String? = nil, what: String) -> Result<Typed, NotTyped> {
        let word = NodeIds.code(action: action)
        let shown = code ?? word
        let outcome = ask(approval: approval, code: shown, what: what, word: code == nil ? nil : word)
        guard outcome == .typed else { return .failure(NotTyped(outcome: outcome)) }
        return .success(Typed(words: [shown, word]))
    }

    /// The token for a code a sequence of `VibeNode`'s asked through `ask` and was typed (`StopSequence`'s `typed`
    /// step, which hands the action to the stop after): `ask` itself, then the token for `code`.
    static func asked(code: String, what: String) -> (TypedOutcome, Typed?) {
        let outcome = ask(code: code, what: what)
        return (outcome, outcome == .typed ? Typed(words: [code]) : nil)
    }

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

extension TypedWord {
    /// Asks `question` on the controlling terminal (`/dev/tty` alone) and reads one line there, at most 120 bytes: what
    /// was typed, trimmed; nil with no terminal.
    static func line(_ question: String) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        _ = question.withCString { Sys.write(fd, $0, strlen($0)) }
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let got = Sys.read(fd, &byte, 1)
            if got < 0, errno == EINTR { continue }
            guard got == 1 else { break }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            line.append(byte)
            if line.count > 120 { break }
        }
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

extension Result where Success == Typed, Failure == NotTyped {
    /// What the command says when the prompt wasn't answered with the code (empty once it was).
    var refusal: String {
        if case .failure(let not) = self { return not.refusal }
        return ""
    }
}
