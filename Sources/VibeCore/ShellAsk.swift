import Foundation

/// A shell an agent asks the user to open: `vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…` (Resources/bin, on every
/// session's PATH; it runs `vibeswitcher-mcp --shell-request …`). For a long-running program that needs a real terminal
/// (one that asks its operator questions, or files wallet requests with vs-wallet), which an agent's own Bash can't give.
///
/// Filed as vs-wallet's requests are (`WalletAsk`): the session host says which session the filing process runs in and
/// stamps the request's exact bytes for it (`WalletStamp`, the same seal: these bytes never parse as a wallet request,
/// nor a wallet request's as these), 0600 in `folder`. The app shows only a request the host stamped, as a card in the
/// asking session's chat with the folder and the exact command; nothing starts until the user presses Run there (or
/// Settings › Agents lets agents open shells without asking). Run starts an ordinary New Shell session in that folder,
/// its shell given the command at launch (`spawnRequest`), never typed into it. What happened goes back to the asking
/// session as a message (`message`), and once the command ends, how it ended: its exit status, how long it ran and the
/// last lines of its output, capped and redacted (`ending`, from what the session host captured: `CommandCapture`).
public struct ShellRequest: Codable, Equatable, Sendable {
    public static let format = "vs-shell-request v1"
    /// The request file at most, the command included.
    public static let maxBytes = 16 * 1024
    /// Unanswered this long, it expires.
    public static let lifetime: TimeInterval = 30 * 60

    public var format: String
    /// Lower-case UUID; also the file's name.
    public var id: String
    /// The asking session's id, lower case, as the host placed the filing process.
    public var session: String
    /// The folder the shell starts in: absolute, symbolic links resolved.
    public var cwd: String
    /// The shell line run, exactly as shown on the card.
    public var command: String
    /// A name for the new session (may be empty).
    public var label: String
    /// Seconds since 1970, by the filing process's clock.
    public var createdAt: Double

    public init(id: String = UUID().uuidString.lowercased(), session: String, cwd: String, command: String, label: String, createdAt: Date) {
        format = Self.format
        self.id = id
        self.session = session.lowercased()
        self.cwd = cwd
        self.command = command
        self.label = label
        self.createdAt = createdAt.timeIntervalSince1970
    }

    public var created: Date { Date(timeIntervalSince1970: createdAt) }
    public var expiresAt: Date { created.addingTimeInterval(Self.lifetime) }

    /// The bytes filed (and stamped): sorted keys, so the same request is always the same bytes. Refused when it breaks a
    /// rule of the format (`check`).
    public func encoded() throws -> Data {
        try check()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ShellAsk.Refusal("the request is over \(Self.maxBytes / 1024) KiB") }
        return data
    }

    /// The request in `data`, only when `data` is exactly what `encoded()` writes for it: anything else (another field,
    /// another order, an escape written differently, over 16 KiB, a NUL byte) is refused, not read some other way.
    public static func parse(_ data: Data) throws -> ShellRequest {
        guard data.count <= maxBytes else { throw ShellAsk.Refusal("the request is over \(maxBytes / 1024) KiB") }
        guard !data.contains(0) else { throw ShellAsk.Refusal("the request holds a NUL byte") }
        let request: ShellRequest
        do { request = try JSONDecoder().decode(ShellRequest.self, from: data) } catch { throw ShellAsk.Refusal("it isn't a shell request") }
        guard try request.encoded() == data else { throw ShellAsk.Refusal("it isn't written as vs-shell writes a request") }
        return request
    }

    /// The format's rules. One rule per field, no exceptions: what doesn't fit is refused.
    public func check() throws {
        guard format == Self.format else { throw ShellAsk.Refusal("format: not \(Self.format)") }
        for (name, value) in [("id", id), ("session", session)] {
            guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
                throw ShellAsk.Refusal("\(name): a lower-case UUID")
            }
        }
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: Self.hidden), cwd.utf8.count <= 4096,
              cwd == "/" || !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ShellAsk.Refusal("cwd: an absolute folder path, written plainly (no ., .., //, trailing / or control characters)")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShellAsk.Refusal("command: empty") }
        // What the card shows is what runs: no character that draws nothing or moves what's drawn (controls but tab and
        // newline, format characters such as right-to-left overrides).
        guard !command.unicodeScalars.contains(where: { $0 != "\t" && $0 != "\n" && Self.hidden($0) }) else {
            throw ShellAsk.Refusal("command: a control or invisible format character (only tab and newline are taken)")
        }
        // Nor any blank space that could push part of it out of sight: no leading or trailing space, no blank line,
        // no run of more than 16 spaces or tabs.
        guard command == command.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.allSatisfy { $0 == " " || $0 == "\t" } }),
              Self.longestBlankRun(command) <= 16 else {
            throw ShellAsk.Refusal("command: blank lines, leading or trailing blanks, or more than 16 spaces in a row (they can hide part of it)")
        }
        guard label.count <= 80, !label.unicodeScalars.contains(where: Self.hidden) else {
            throw ShellAsk.Refusal("label: up to 80 characters, no control or format characters")
        }
        guard createdAt.isFinite, createdAt > 0 else { throw ShellAsk.Refusal("createdAt: not a time") }
    }

    /// The most spaces and tabs in a row in `text`.
    static func longestBlankRun(_ text: String) -> Int {
        var longest = 0, run = 0
        for scalar in text.unicodeScalars {
            run = scalar == " " || scalar == "\t" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// A control (Cc), format (Cf), line or paragraph separator character, or a non-character.
    static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate: return true
        default: return scalar.properties.isNoncharacterCodePoint
        }
    }
}

public enum ShellAsk {
    /// Where filed requests wait for the user: `~/.vibeswitcher/shell-requests/asked/<id>.json`, its stamp
    /// `<id>.seal` beside it, and what became of it `.<id>.answer`.
    public static var folder: URL { VibePaths.root.appendingPathComponent("shell-requests/asked", isDirectory: true) }

    /// The variable the new session's shell gets the command in (`spawnRequest`).
    public static let commandVariable = "VIBESWITCHER_SHELL_COMMAND"

    public static let usage = """
        usage: vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…

        Asks the user to open a new shell session in VibeSwitcher that runs COMMAND in DIR (this folder unless given):
        for a long-running program that needs a real terminal (one that asks questions on stdin, or files wallet
        requests with vs-wallet). A card in this session's chat shows the folder and the exact command; nothing runs
        until the user presses Run there (unless they let agents open shells without asking, in Settings › Agents).
        The words after -- are joined with spaces into one shell line, run by the user's login shell, which stays open
        as an interactive shell when the command ends: quoting inside a word is lost, so give a line that needs quotes
        as one argument (vs-shell run -- "bash -c 'make && make install'"); a word the shell would split or read again
        is warned about. What happens (started, with the new session's name; declined; expired after 30 minutes) comes
        to this session as a message, and when the command ends, another with its exit status, how long it ran and the
        last lines of its output (up to 40 lines, secrets masked).

          --cwd     the folder to start in (relative to this one); it must exist
          --label   a name for the new session (up to 80 characters)
        Exit status: 0 filed, 1 refused, 2 usage.
        """

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// `vs-shell …` as the CLI runs it: what to print, and the exit status (0 filed, 1 refused, 2 usage). `cwd`: the
    /// process's folder. `vault`: the session host's (`LeadVault.standard` in the CLI), which says which session the
    /// calling process runs in, from that process, and stamps the request's bytes for it. `atOnce`: Settings › Agents
    /// lets agents open shells without asking (only what the output says; the app decides).
    public static func run(_ arguments: [String], cwd: String, folder: URL = ShellAsk.folder, now: Date = Date(),
                           vault: LeadVault, atOnce: Bool = false) -> (status: Int32, output: String, error: String) {
        guard let verb = arguments.first, verb == "run" else {
            return arguments.first.map { ["help", "--help", "-h"].contains($0) } == true ? (0, usage, "") : (2, "", usage)
        }
        var words = arguments.dropFirst().makeIterator()
        var values: [String: String] = [:]
        var command: [String]?
        while let word = words.next() {
            if word == "--" { command = Array(IteratorSequence(words)); break }
            guard ["--cwd", "--label"].contains(word) else { return (2, "", "vs-shell: unknown option \(word)\n\n\(usage)") }
            guard let value = words.next() else { return (2, "", "vs-shell: \(word) needs a value\n\n\(usage)") }
            guard values[word] == nil else { return (2, "", "vs-shell: \(word) is given twice\n\n\(usage)") }
            values[word] = value
        }
        guard let command, !command.isEmpty else { return (2, "", "vs-shell: no command: put it after --\n\n\(usage)") }
        do {
            let folderPath = try directory(values["--cwd"] ?? ".", from: cwd)
            let session: String
            do {
                session = try vault.walletSession()
            } catch {
                throw Refusal("VibeSwitcher's session host didn't say which of its sessions this process runs in (\(error)): "
                              + "run it from the agent's own session in VibeSwitcher, with VibeSwitcher running")
            }
            let request = ShellRequest(session: session, cwd: folderPath, command: command.joined(separator: " "),
                                       label: values["--label"] ?? "", createdAt: now)
            let bytes = try request.encoded()
            let digest = WalletStamp.digest(bytes)
            let seal: String
            do {
                seal = try vault.sealWallet(session: session, digest: digest)
            } catch {
                throw Refusal("VibeSwitcher's session host didn't stamp the request (\(error))")
            }
            try file(request, stamp: WalletStamp(session: session, digest: digest, seal: seal), in: folder)
            let then = "What happens (started, with the new session's name; declined; expired) will come to this session as a message, "
                + "and when the command ends, its exit status and the last lines of its output; don't file it again."
                + (splitWarning(command).map { "\n\n" + $0 } ?? "")
            if atOnce {
                return (0, "Filed shell request \(request.id). The user lets agents open shells without asking, so VibeSwitcher starts it "
                           + "in a new shell session in a moment; its card in this session's chat records it. \(then)", "")
            }
            return (0, "Filed shell request \(request.id): its card waits in this session's chat in VibeSwitcher, showing the folder "
                       + "and the exact command, and nothing runs until the user presses Run there. It expires in 30 minutes "
                       + "unanswered. \(then)", "")
        } catch let refusal as Refusal {
            return (1, "", "vs-shell: refused: \(refusal.description)")
        } catch {
            return (1, "", "vs-shell: refused: \(error)")
        }
    }

    /// Characters a shell reads in a word: a word holding one, joined with the others by spaces, isn't one word any more.
    static let shellReads = Set(" \t\n;&|<>()$`\\\"'*?")

    /// The warning for words the user's shell would split or read again once joined into one line (user report
    /// 2026-11-12: `vs-shell run -- bash -c 'git log -1 --oneline && …'` ran `bash -c git log …`, and git printed its
    /// usage); nil when there's nothing to warn of. One word alone is the whole line, as meant.
    static func splitWarning(_ words: [String]) -> String? {
        guard words.count > 1 else { return nil }
        let read = words.enumerated().filter { $0.element.contains(where: shellReads.contains) }
        guard !read.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        let meant = words.map { word in word.contains(where: shellReads.contains) ? RecentProjects.shellQuote(word) : word }.joined(separator: " ")
        let which = read.map { "word \($0.offset + 1) (`\($0.element.count > 60 ? String($0.element.prefix(60)) + "…" : $0.element)`)" }
            .joined(separator: ", ")
        return "Warning: \(which) holds spaces, quotes or characters the shell reads. vs-shell joins the words with spaces into one "
            + "line, so the user's shell reads them again, and the card runs exactly `\(line)`. If you meant each word as one word, "
            + "ask the user to decline this card and file it again with the whole line as one argument, quoted for the shell: "
            + "vs-shell run -- \(RecentProjects.shellQuote(meant))"
    }

    /// `path` (relative to `cwd`) as an existing folder's real path, symbolic links resolved; refused otherwise.
    static func directory(_ path: String, from cwd: String) throws -> String {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw Refusal("--cwd: no folder named") }
        let joined = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        guard let real = realpath(joined, nil) else { throw Refusal("--cwd: no such folder: \(joined)") }
        defer { free(real) }
        let resolved = String(cString: real)
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Refusal("--cwd: not a folder: \(joined)") }
        return resolved
    }

    /// Files `request` with the host's `stamp` on its bytes: `<id>.seal`, then `<id>.json`, each 0600 in a 0700 folder.
    /// Refused when the stamp isn't for these bytes and the session the request names.
    public static func file(_ request: ShellRequest, stamp: WalletStamp, in folder: URL = ShellAsk.folder) throws {
        let bytes = try request.encoded()
        guard stamp.session == request.session, stamp.digest == WalletStamp.digest(bytes) else {
            throw Refusal("the session host's stamp isn't for this request")
        }
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(JSONEncoder().encode(stamp), to: folder.appendingPathComponent("\(request.id).seal"))
        try VibePaths.writePrivate(bytes, to: folder.appendingPathComponent("\(request.id).json"))
    }

    /// The requests filed in `folder`, oldest first, each parsed again strictly (the folder is a file anyone's shell can
    /// write) with the stamp filed beside it (`stamps`, by id; the app asks the host whether each is its own). One that
    /// doesn't parse, whose id isn't its name's, or with no stamp for its bytes and the session it names, is in `refused`.
    public static func filed(in folder: URL = ShellAsk.folder)
        -> (requests: [ShellRequest], stamps: [String: WalletStamp], refused: [(file: URL, why: String)]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var requests: [ShellRequest] = []
        var stamps: [String: WalletStamp] = [:]
        var refused: [(URL, String)] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name)
            do {
                let data = try WalletAsk.read(file)
                let request = try ShellRequest.parse(data)
                guard "\(request.id).json" == name else { throw Refusal("its id \(request.id) isn't its name's") }
                guard let stamp = try? JSONDecoder().decode(WalletStamp.self, from: WalletAsk.read(folder.appendingPathComponent("\(request.id).seal"))),
                      stamp.digest == WalletStamp.digest(data), stamp.session == request.session else {
                    throw Refusal("it has no session host stamp for its bytes and session")
                }
                requests.append(request)
                stamps[request.id] = stamp
            } catch {
                refused.append((file, "\(error)"))
            }
        }
        return (requests.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }, stamps, refused)
    }

    /// What became of a request, beside it (`.<id>.answer`: `filed` reads no dot-file). Written before anything starts,
    /// so a request is never started twice.
    public struct Answer: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case starting, started, declined, expired, failed }
        public var state: State
        /// Seconds since 1970.
        public var at: Double
        /// Started without the user's click (Settings › Agents).
        public var auto: Bool
        /// The new session (started).
        public var shell: String?
        /// Its name (started).
        public var name: String?
        /// Why it didn't start (failed).
        public var why: String?
        /// The asking session was told (or is gone, so no one can be).
        public var told: Bool
        /// Started by a build that tells the asker how the command ended: false until it's told (or the asker is
        /// gone), then true. Nil for every other answer, and a start from before (never followed).
        public var endTold: Bool?
        /// Its card was dismissed while the end is still to be told: the files stay until it is (`endTold`).
        public var dismissed: Bool?

        public init(state: State, at: Date, auto: Bool = false, shell: String? = nil, name: String? = nil, why: String? = nil, told: Bool = false,
                    endTold: Bool? = nil) {
            self.state = state
            self.at = at.timeIntervalSince1970
            self.auto = auto
            self.shell = shell
            self.name = name
            self.why = why
            self.told = told
            self.endTold = endTold
        }

        /// The command's end is still to be told to the asker.
        public var awaitsEnd: Bool { state == .started && endTold == false }
    }

    static func answerFile(_ id: String, in folder: URL) -> URL { folder.appendingPathComponent(".\(id).answer") }

    public static func answer(_ id: String, in folder: URL = ShellAsk.folder) -> Answer? {
        (try? WalletAsk.read(answerFile(id, in: folder))).flatMap { try? JSONDecoder().decode(Answer.self, from: $0) }
    }

    public static func record(_ answer: Answer, for id: String, in folder: URL = ShellAsk.folder) throws {
        try VibePaths.writePrivate(JSONEncoder().encode(answer), to: answerFile(id, in: folder))
    }

    /// Removes a filed request, its stamp and its answer.
    public static func remove(_ id: String, in folder: URL = ShellAsk.folder) {
        for file in ["\(id).json", "\(id).seal", ".\(id).answer"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
    }

    /// The session the app starts for `request`: an ordinary New Shell (the user's login shell, the app's tools on its
    /// PATH, as the host gives every session) in its folder, whose shell gets the command in `commandVariable` and
    /// runs it, then stays open as an interactive shell (`keepShell`). The command is never typed into the terminal,
    /// nor pasted into the shell's line: `eval` of the variable runs it as one whole line, whatever it ends with.
    ///
    /// Before the command the line tells the terminal it starts (`ShellTidy.start`), and after it how it ended, with its
    /// exit status (`ShellTidy.report`): the host keeps the output between, its end (`CommandCapture`), and that with the
    /// session, and a shell whose command went well and that nobody uses leaves by itself (`ShellTidy`).
    public static func spawnRequest(_ request: ShellRequest, cols: Int = 120, rows: Int = 36) -> SpawnRequest {
        SpawnRequest(cwd: request.cwd, command: "\(ShellTidy.launchLine) \(ShellTidy.report)", env: [commandVariable: request.command],
                     cols: cols, rows: rows, keepShell: true, label: sessionLabel(request), agent: nil)
    }

    /// "Shell", or "Shell: <label>".
    public static func sessionLabel(_ request: ShellRequest) -> String {
        request.label.isEmpty ? "Shell" : "Shell: \(request.label)"
    }

    static func head(_ request: ShellRequest) -> String {
        "Shell request \(request.id) (`\(request.command.count > 120 ? String(request.command.prefix(120)) + "…" : request.command)` in \(request.cwd))"
    }

    /// What the asking session hears once the command of a started request ended, from its shell session as the host
    /// has it (`session`; nil when the host no longer has it): nil while the command runs. Its exit status, how long it
    /// ran, and the last lines it printed (`CommandEnd.tail`, capped by the host, secrets masked here); what wasn't
    /// captured is said, never guessed.
    public static func ending(_ request: ShellRequest, _ answer: Answer, session: HostSession?) -> String? {
        let head = head(request), name = "\"\(answer.name ?? sessionLabel(request))\""
        guard let session else {
            return "\(head): its shell session \(name) is gone from VibeSwitcher before the command said how it ended, so its exit "
                + "status and output weren't captured. Ask the user how it went."
        }
        guard let end = session.commandEnd else {
            guard !session.isLive else { return nil }
            let shell = session.exit.map { " (its shell exited with status \($0.status))" } ?? ""
            return "\(head): its shell session \(name) ended\(shell) before the command said how it ended (it may have run `exit`, or "
                + "the session was closed), so its exit status and output weren't captured. Ask the user how it went."
        }
        let ran = end.startedAt.map { " after \(Durations.short(end.at.timeIntervalSince($0)))" } ?? ""
        var text: String
        switch (end.ok, end.status) {
        case (true, _): text = "\(head) succeeded: the command exited with status 0\(ran)."
        case (false, let status?): text = "\(head) FAILED: the command exited with status \(status)\(ran)."
        case (false, nil): text = "\(head) FAILED: the command exited non-zero\(ran); its exact status wasn't captured."
        }
        switch end.tail {
        case nil:
            text += " Its output wasn't captured (VibeSwitcher didn't see the command start); the user sees it in session \(name)."
        case let tail? where tail.isEmpty:
            text += " It printed nothing."
        case let tail?:
            let shown = Redaction.secrets(in: tail)
            let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).count
            var fence = "```"
            while shown.contains(fence) { fence += "`" }
            text += " \(end.cut ? "The last \(lines) lines of its output (earlier ones left out" : "Its output (\(lines) line\(lines == 1 ? "" : "s")"), "
                + "secrets masked):\n\(fence)\n\(shown)\n\(fence)"
        }
        return text + "\nThe shell stays open in session \(name) as an interactive shell; what's typed there afterwards isn't sent to you."
    }

    /// What the asking session hears once the request is answered (nil while it's starting).
    public static func message(_ request: ShellRequest, _ answer: Answer) -> String? {
        let head = head(request)
        switch answer.state {
        case .starting: return nil
        case .started:
            return "\(head) started\(answer.auto ? " at once (the user lets agents open shells without asking)" : ": the user pressed Run")"
                + ", in a new shell session named \"\(answer.name ?? sessionLabel(request))\" (session \(answer.shell ?? "?")). It runs in "
                + "that session's terminal, which stays open as a shell when the command ends; the user sees it there. A wallet "
                + "request it files with vs-wallet shows as a card under that session."
                + (answer.endTold == nil ? "" : " When the command ends, its exit status and the last lines of its output come to you as another message.")
        case .declined: return "\(head) was declined by the user: nothing ran."
        case .expired:
            return "\(head) expired after 30 minutes without the user's answer: nothing ran. If it's still needed, ask the user, "
                + "or file it again with vs-shell run."
        case .failed: return "\(head) didn't start (\(answer.why ?? "the session host refused it")): nothing ran."
        }
    }
}
