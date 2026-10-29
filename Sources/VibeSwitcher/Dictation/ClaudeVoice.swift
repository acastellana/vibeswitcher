import Foundation
import VibeCore

/// A Claude Code session that dictation drives through its own /voice (`ClaudeVoiceRun`): its keys and its screen.
struct ClaudeVoiceSession {
    /// Its host session (what else types there waits while a dictation goes in: `ClaudeVoiceRun.busy`).
    var id: UUID?
    /// Its folder: Claude's project settings are read there.
    var folder: String?
    /// Raw keys for the session's program, sent at once; false when they couldn't go out.
    var keys: ([UInt8]) -> Bool
    /// Its screen with how it's drawn (nil: it couldn't be read), answered on the main thread.
    var screen: (@escaping (LeadDelivery.Screen?) -> Void) -> Void
    /// A command typed in and submitted as the composer sends a message (`/voice hold`, after your click); false when it
    /// didn't go.
    var command: (String) -> Bool
    /// Tells its program its terminal has focus (`CSI I`), only ever sent to one that asked for focus events: Claude
    /// draws its level cursor only then. False when it didn't go.
    var focusIn: () -> Bool = { false }
    /// Tells its program the terminal's real focus again: `CSI O` unless its pane has it.
    var focusBack: () -> Void = {}
}

/// What Claude Code's screen says about its dictation (code.claude.com/docs/en/voice-dictation).
enum ClaudeVoiceScreen {
    /// Its footer, under the prompt box: `keep holding…` while a held key warms up, `listening…` while it records
    /// (hold mode), `● REC · tap to send` (tap mode, which sends by itself), `Voice: processing…` once it stops. One
    /// signal among several: where it shows depends on the layout (2.1.312 puts `listening…` in the notices at the
    /// footer's right, or in its first row; a custom status line takes the footer's left), so it may not be on screen.
    enum Footer: Equatable { case none, warming, listening, tap, processing }

    static func footer(_ text: String) -> Footer {
        let lines = text.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        guard let rule = lines.lastIndex(where: { $0.filter { $0 == "─" }.count >= 20 }) else { return .none }
        let below = lines[(rule + 1)...].joined(separator: "\n").lowercased()
        if below.contains("tap to send") { return .tap }
        if below.contains("listening…") || below.contains("listening...") { return .listening }
        if below.contains("keep holding") { return .warming }
        if below.contains("processing…") { return .processing }
        return .none
    }

    /// What Claude Code (2.1.312, read from its code) draws in its prompt box itself about its dictation, footer aside:
    /// a held Space's first two presses go in as spaces and its later repeats are swallowed (`warmupTyped`), until
    /// recording starts and those two go; while it records, its level cursor stands where the caret was (a bar glyph,
    /// grey below a low level, else a moving hue) and the words heard so far show dim. With /voice off, every Space
    /// stays typed. Only a focused terminal gets the caret and the level cursor.
    struct Prompt: Equatable {
        /// Spaces typed into a box that holds nothing else (0: none); nil when it holds something else, or there's no box.
        var spaces: Int?
        /// The level cursor at the box's end.
        var meter = false
        /// What's dim in the box, less the level cursor.
        var dim = ""
    }

    /// The spaces a held Space leaves in the box while Claude's dictation warms up (2.1.312: its first two presses; the
    /// later repeats are swallowed).
    static let warmupTyped = 2
    /// The presses its warmup takes before it records (2.1.312): no words can be heard before.
    static let warmupPresses = 5

    static func prompt(_ screen: LeadDelivery.Screen) -> Prompt {
        let lines = screen.text.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let rules = lines.indices.filter { lines[$0].filter { $0 == "─" }.count >= 20 }
        guard rules.count >= 2 else { return Prompt() }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        guard top + 1 < bottom, let marker = Array(lines[top + 1]).firstIndex(of: "❯") else { return Prompt() }
        let runs = screen.runs ?? []
        var prompt = Prompt()
        // The box's cells after the marker and the space after it, row by row.
        var cells: [(row: Int, column: Int, character: Character)] = []
        for row in (top + 1)..<bottom {
            let line = Array(lines[row])
            let from = row == top + 1 ? marker + 2 : 0
            cells += line.indices.filter { $0 >= from }.map { (row, $0, line[$0]) }
        }
        let run = { (cell: (row: Int, column: Int, character: Character)) in
            runs.first { $0.row == cell.row && (($0.column)..<($0.column + $0.length)).contains(cell.column) }
        }
        // The level cursor: a bar glyph drawn in a colour, neither faint nor inverse, last in the box.
        if let last = cells.last(where: { !$0.character.isWhitespace }), meter.contains(last.character), last.character != " ",
           let drawn = run(last), drawn.color != nil, !drawn.faint, !drawn.inverse {
            prompt.meter = true
            cells.removeAll { $0 == last }
        }
        let dim = cells.filter { run($0)?.isDim == true }
        prompt.dim = String(dim.map(\.character)).trimmingCharacters(in: .whitespaces)
        // The caret: an inverse cell. The spaces typed are the plain ones it follows, first in the box.
        let caret = cells.first { run($0)?.inverse == true && !(run($0)?.isDim ?? false) }
        let plain = { (cell: (row: Int, column: Int, character: Character)) in
            !dim.contains { $0 == cell } && !(caret.map { $0 == cell } ?? false)
        }
        guard cells.filter(plain).allSatisfy({ $0.character == " " }) else { return prompt }
        prompt.spaces = cells.prefix { $0.row == top + 1 && $0.character == " " && plain($0) }.count
        return prompt
    }

    /// What a read shows of Claude's dictation, by name: what notices and breadcrumbs say, never the screen's text.
    enum Seen: String {
        case nothing = "nothing"
        /// Spaces typed and kept, as with /voice off.
        case typed = "spaces typed"
        case warming = "warming up"
        /// Its footer's `listening…` or its level cursor: it records, and a Space keeps it recording.
        case recording = "recording"
        /// Words heard, dim, with neither its footer nor its level cursor to say it still records (they stay dim while
        /// it processes).
        case heard = "words heard"
        case processing = "processing"
        case tap = "tap mode"
    }

    /// What `screen` shows, `sent` Spaces after a box that showed `dimBefore` dim (its placeholder or suggestion).
    static func seen(_ screen: LeadDelivery.Screen, sent: Int, dimBefore: String = "") -> Seen {
        let footer = footer(screen.text)
        let prompt = prompt(screen)
        if footer == .tap { return .tap }
        if footer == .listening || prompt.meter { return .recording }
        if footer == .processing { return .processing }
        if footer == .warming { return .warming }
        if let spaces = prompt.spaces, spaces > 0 {
            // Kept beyond what a warmup leaves, or every one kept (one may still be on its way): typed. Fewer: swallowed.
            return spaces > warmupTyped || sent <= spaces + 1 ? .typed : .warming
        }
        // Before the warmup's presses, a dim change is the box's own (its placeholder redrawn with a caret on focus).
        if sent >= warmupPresses, prompt.dim != dimBefore, prompt.dim.contains(where: { $0.isLetter || $0.isNumber }) { return .heard }
        return .nothing
    }

    /// The messages Claude shows about its dictation.
    enum Signal: CaseIterable, Hashable {
        case enabled, unknownCommand, needsAccount, policy, microphone, noAudio, noSpeech, failed

        var phrases: [String] {
            switch self {
            case .enabled: return ["Voice mode enabled"]
            case .unknownCommand: return ["Unknown command: /voice"]
            case .needsAccount: return ["Voice mode requires a Claude.ai account"]
            case .policy: return ["Voice mode is disabled by your organization"]
            case .microphone: return ["Microphone access is denied"]
            case .noAudio: return ["No audio detected from microphone"]
            case .noSpeech: return ["No speech detected"]
            case .failed: return ["Voice connection failed", "Voice stream error", "Voice input is failing repeatedly", "Dictation error"]
            }
        }

        /// What the composer says when Claude shows it; nil for `enabled`.
        var notice: String? {
            switch self {
            case .enabled: return nil
            case .unknownCommand:
                return "This session's Claude Code has no /voice: it needs a claude.ai sign-in (run /login there), and an ANTHROPIC_API_KEY or another provider in use takes precedence over one."
            case .needsAccount: return "Claude's dictation needs a claude.ai sign-in: run /login in the session, then try again."
            case .policy: return "Claude's dictation is turned off by your organization's policy."
            // VibeSwitcher's: macOS asks about it for the claude in its sessions.
            case .microphone, .noAudio: return DictationController.microphoneNotice
            case .noSpeech: return "Claude didn't catch any words: hold the mic and speak a little closer."
            case .failed: return "Claude's dictation couldn't reach its service: check the network and try again."
            }
        }

        /// Turning dictation on (`/voice hold`) may help.
        var offersTurnOn: Bool { self == .unknownCommand }
    }

    /// How many times each message shows on `text` (a new one is one more than before).
    static func signals(_ text: String) -> [Signal: Int] {
        var counts: [Signal: Int] = [:]
        for signal in Signal.allCases {
            let count = signal.phrases.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
            if count > 0 { counts[signal] = count }
        }
        return counts
    }

    /// The conversation's lines: the screen above the prompt box (all of it when no box is shown).
    static func conversation(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let rules = lines.indices.filter { lines[$0].filter { $0 == "─" }.count >= 20 }
        return rules.count >= 2 ? Array(lines[..<rules[rules.count - 2]]) : lines
    }

    /// Claude's first message about its dictation after the newest echo of `command` in the conversation (not the box
    /// it's typed in), once the conversation isn't what it was at the click (`before`): what it answered to this one.
    /// Unlike a count of messages, it isn't fooled by an earlier answer scrolling off as the new one comes in.
    static func answer(to command: String, in text: String, before: [String]) -> Signal? {
        let lines = conversation(text)
        guard lines != before, let echo = lines.lastIndex(where: { $0.contains(command) }) else { return nil }
        let after = lines[(echo + 1)...].joined(separator: "\n")
        return Signal.allCases.compactMap { signal -> (Signal, String.Index)? in
            signal.phrases.compactMap { after.range(of: $0)?.lowerBound }.min().map { (signal, $0) }
        }.min { $0.1 < $1.1 }?.0
    }

    /// The messages shown more often in `now` than in `before`, in `Signal`'s order.
    static func new(_ now: [Signal: Int], since before: [Signal: Int]) -> [Signal] {
        Signal.allCases.filter { (now[$0] ?? 0) > (before[$0] ?? 0) }
    }

    /// Whether `text` is what grew out of the words heard (`live`, shown dim while recording), not something typed
    /// before it: it starts with one of the first three words heard, the first word heard is among its first three, or
    /// only its first word was revised (its second is the second heard). Nothing heard shown: it can't be told, so yes.
    static func grew(_ text: String, from live: String) -> Bool {
        let words = { (text: String) in
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let (heard, final) = (words(live), words(text))
        guard !heard.isEmpty else { return true }
        guard let first = final.first else { return false }
        return heard.prefix(3).contains(first) || final.prefix(3).contains(heard[0])
            || (heard.count > 1 && final.count > 1 && heard[1] == final[1])
    }

    /// The glyphs of Claude's recording-level cursor, which rises and falls with the microphone's level.
    static let meter: Set<Character> = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// Nothing in `draft` but the level cursor (and spaces).
    static func meterOnly(_ draft: String) -> Bool {
        draft.allSatisfy { meter.contains($0) || $0.isNewline }
    }

    /// The box's draft as one line: the screen wraps it, and a transcript has no line breaks of its own; a level
    /// cursor left at its end isn't part of it.
    static func line(_ draft: String) -> String {
        let joined = draft.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(joined.reversed().drop(while: { meter.contains($0) }).reversed())
    }
}

/// What dictation may not use of Claude's own settings (`~/.claude/settings.json`, read, never written): tap mode and
/// `voice.autoSubmit` both send a transcript of three words or more by themselves.
struct ClaudeVoiceSettings: Equatable, Sendable {
    var mode: String?
    var autoSubmit = false
    /// Claude's dictation key (`voice:pushToTalk` in its keybindings' Chat context): Space unless rebound; nil when it's
    /// unbound. VibeSwitcher holds Space only.
    var pushToTalk: String? = "space"

    /// Why dictation won't drive Claude's /voice with these settings; nil when it can. `offer`: `/voice hold` fixes it.
    var refusal: (text: String, offer: Bool)? {
        if autoSubmit {
            return ("Claude's dictation is set to send what you say by itself (voice.autoSubmit in ~/.claude/settings.json), so VibeSwitcher won't start it: nothing goes out without you. Turn autoSubmit off to dictate here.", false)
        }
        if mode == "tap" {
            return ("Claude's dictation is in tap mode, which sends what you say by itself; VibeSwitcher only uses hold mode.", true)
        }
        guard let key = pushToTalk else {
            return ("Claude's dictation key is unbound (voice:pushToTalk in ~/.claude/keybindings.json), so VibeSwitcher can't hold it.", false)
        }
        if key != "space" {
            return ("Claude's dictation key is \(key) (voice:pushToTalk in ~/.claude/keybindings.json); VibeSwitcher only holds Space, so it didn't start. Hold \(key) in the terminal to dictate there.", false)
        }
        return nil
    }

    /// The key bound to `voice:pushToTalk` in a keybindings file's Chat context (`{"bindings": [{"context": "Chat",
    /// "bindings": {"meta+k": "voice:pushToTalk", "space": null}}]}`): a key bound to it replaces Space; Space bound
    /// to null leaves none. No file, or none of that: Space.
    static func pushToTalk(_ data: Data?) -> String? {
        guard let data, data.count <= 1 << 20, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = object["bindings"] as? [[String: Any]] else { return "space" }
        var bound: String?
        var spaceUnbound = false
        for block in blocks where (block["context"] as? String)?.lowercased() == "chat" {
            for (key, action) in block["bindings"] as? [String: Any] ?? [:] {
                if action as? String == "voice:pushToTalk" { bound = key.lowercased() }
                if key.lowercased() == "space", action is NSNull { spaceUnbound = true }
            }
        }
        return bound ?? (spaceUnbound ? nil : "space")
    }

    static func parse(_ data: Data?) -> ClaudeVoiceSettings {
        merged([data])
    }

    /// Settings files from the lowest to the highest precedence: a later one's `voice.mode` and `voice.autoSubmit`
    /// win over an earlier one's.
    static func merged(_ files: [Data?]) -> ClaudeVoiceSettings {
        var settings = ClaudeVoiceSettings()
        for data in files {
            guard let data, data.count <= 1 << 20, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let voice = object["voice"] as? [String: Any] else { continue }
            if let mode = voice["mode"] as? String { settings.mode = mode }
            if let autoSubmit = voice["autoSubmit"] as? Bool { settings.autoSubmit = autoSubmit }
        }
        return settings
    }

    /// Where Claude Code reads settings, lowest precedence first: the user's (its config folder, `CLAUDE_CONFIG_DIR` or
    /// ~/.claude, from the home this process runs on: a test's scratch home), the project's and its local ones in
    /// `folder`, then the Mac's managed ones.
    static func files(folder: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.claude"
        var paths = [config + "/settings.json"]
        if let folder { paths += [folder + "/.claude/settings.json", folder + "/.claude/settings.local.json"] }
        return paths + ["/Library/Application Support/ClaudeCode/managed-settings.json"]
    }

    /// Claude's keybindings, in its config folder.
    static func keybindings(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.claude") + "/keybindings.json"
    }

    /// Blocks: never on the main thread.
    static func read(folder: String?) -> ClaudeVoiceSettings {
        var settings = merged(files(folder: folder).map { FileManager.default.contents(atPath: $0) })
        settings.pushToTalk = pushToTalk(FileManager.default.contents(atPath: keybindings()))
        return settings
    }
}

/// One dictation through Claude Code's /voice in hold mode, from the press to the text in the composer. While held,
/// Space goes in as key repeats (Claude tells a held key from rapid repeats, after a warmup it shows as `keep
/// holding…`, then `listening…`); let go, the repeats stop, Claude writes the transcript into its prompt box without
/// sending it, and once the box shows the same text twice it's taken out (⌃U, read back until the box is empty) and
/// handed over. Only into an empty box, never with Enter; a box that shows anything else is left alone. Esc cancels
/// (Claude's own cancel). Main thread.
final class ClaudeVoiceRun {
    enum Outcome: Equatable {
        /// What Claude wrote, moved out of its box.
        case text(String)
        /// What happened instead; `offer`: turning Claude's dictation on (`/voice hold`) may help.
        case notice(String, offer: Bool)
        case cancelled
    }

    /// While held, a Space goes this often on a timer of its own, however long a read of the screen takes: Claude Code
    /// (2.1.312) takes a key with no repeat for 120 ms as let go, and reads on a busy Mac take longer than that. Reads
    /// only say when to stop.
    static let repeatEvery: TimeInterval = 0.045
    /// The repeats start at the first read after the first Space, or this long after it if that read is slower: tap
    /// mode, which Claude may be in by a setting VibeSwitcher didn't see, records on the first Space and stops on the
    /// next, so a read gets the chance to cancel it (Esc) first; still inside Claude's 120 ms.
    static let firstRepeatWithin: TimeInterval = 0.1
    /// While held, the screen is read this long after each answer.
    static let holdReadEvery: TimeInterval = 0.02
    /// Right after a hold's last Space: End, which in Claude's prompt only moves the caret to the end it's at already.
    /// Any key but its dictation key clears its "a second push sends" state and the 120 ms timer a second push started
    /// (2.1.312's push-to-talk handler: `if(!ut||!$e)qe()`), so a Space that reached it after the transcript went in
    /// can't be half of a double push. Not Esc or ⌃C: those cancel the recording.
    static let disarm: [UInt8] = [0x1b, 0x5b, 0x46]
    /// How often the screen is read.
    static let readEvery: TimeInterval = 0.15
    /// No `listening…` this long after the first Space: Claude's dictation is off, or not in this session.
    static let startWithin: TimeInterval = 3
    /// After the release, how long Claude may take to write the transcript.
    static let finishWithin: TimeInterval = 20
    /// Reads after a ⌃U before the box must be empty, and ⌃U sent at most (a long draft spans lines; each takes one).
    static let clearReads = 12
    static let clearKeys = 4

    static let space: UInt8 = 0x20
    static let escape: UInt8 = 0x1b
    static let killLine: UInt8 = 0x15

    static let holdLonger = "Hold the mic while you speak: Claude starts listening after a moment (“listening…”)."
    /// Its Spaces typed and kept: /voice is off in the session.
    static let didntStart = "Claude's dictation is off in this session: holding Space typed spaces into its prompt box."
    /// Neither off nor recording by the end of the wait: what was seen last, by name.
    static func unclear(_ seen: ClaudeVoiceScreen.Seen) -> String {
        "Claude's dictation didn't start here: no recording seen (last seen: \(seen.rawValue)). Nothing was dictated; its prompt box is as it was."
    }
    static let tapMode = "Claude's dictation is in tap mode, which sends what you say by itself; VibeSwitcher only uses hold mode."
    static let typedMeanwhile = "Something was typed in the terminal meanwhile, so VibeSwitcher left Claude's prompt box alone."
    /// Reads in a row that must show the same text before it's taken (Claude may still be finishing it).
    static let steadyReads = 3

    /// The host sessions a dictation is going into now: nothing else types into them meanwhile (the composer's
    /// messages, held ones, the lead's), or its Enter would send the dictation with it. Main thread.
    nonisolated(unsafe) static var busy: Set<UUID> = []

    private enum Stage { case checking, holding, finishing, clearing, done }

    private let session: ClaudeVoiceSession
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    private let now: () -> Date
    private let onListening: () -> Void
    private let finish: (Outcome) -> Void
    private var stage = Stage.checking
    private var released = false
    private var cancelled = false
    private var listening = false
    private var spaces = 0
    /// The Spaces' timer (nil: none going), and whether the hold's Spaces were followed by `disarm`.
    private var stopSpaces: (() -> Void)?
    private var repeating = false
    private var disarmed = false
    /// The last read no longer showed it recording: the next one says whether it's over.
    private var doubting = false
    /// A read showed it recording by its footer or level cursor, not only by words heard.
    private var recordingShown = false
    private var started = Date.distantPast
    private var finishBy = Date.distantFuture
    private var baseline: [ClaudeVoiceScreen.Signal: Int] = [:]
    /// What the box showed dim before the first Space (its placeholder or suggestion).
    private var dimBefore = ""
    /// What the reads showed, each change once, and the spaces the last one showed typed.
    private var seen: [ClaudeVoiceScreen.Seen] = []
    private var spacesShown = 0
    /// The session was told its terminal has focus (`focusIn`): it's told the real focus again when the run ends.
    private var focusSent = false
    private var stopReads: (() -> Void)?
    private var lastDraft: String?
    private var steady = 0
    /// Something not dim showed in the box while Claude recorded: typed in the terminal, not dictated.
    private var typed = false
    /// The words Claude showed dim while it listened.
    private var live = ""
    private var taken: (shown: String, text: String)?
    private var clearSent = 0
    private var clearRead = 0

    init(session: ClaudeVoiceSession, schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void,
         now: @escaping () -> Date = Date.init, onListening: @escaping () -> Void = {}, finish: @escaping (Outcome) -> Void) {
        self.session = session
        self.schedule = schedule
        self.now = now
        self.onListening = onListening
        self.finish = finish
    }

    /// Reads the box first: only an empty one gets keys.
    func start() {
        if let id = session.id { Self.busy.insert(id) }
        session.screen { [weak self] screen in self?.checked(screen) }
    }

    /// Let go: the repeats stop, and Claude finishes the transcript (or, not listening yet, the spaces go).
    func release() {
        released = true
        guard stage == .holding else { return }
        stopHolding()
        if listening {
            finishing()
        } else {
            tidy { [weak self] in self?.end(.notice(Self.holdLonger, offer: false)) }
        }
    }

    /// Esc in the composer: Claude's own cancel while it listens; afterwards, what it writes is cleared, not kept.
    func cancel() {
        cancelled = true
        switch stage {
        case .holding:
            if listening {
                // Claude's cancel puts back the box as it was; a Space it kept goes too.
                _ = session.keys([Self.escape])
                tidy { [weak self] in self?.end(.cancelled) }
            } else {
                tidy { [weak self] in self?.end(.cancelled) }
            }
        case .checking, .finishing, .clearing, .done:
            break
        }
    }

    // MARK: Holding

    private func checked(_ screen: LeadDelivery.Screen?) {
        guard stage == .checking else { return }
        guard let screen else { return end(.notice("VibeSwitcher couldn't read the session's screen; nothing was dictated.", offer: false)) }
        if cancelled { return end(.cancelled) }
        if released { return end(.notice(Self.holdLonger, offer: false)) }
        switch LeadDelivery.box(in: screen) {
        case .dialog:
            end(.notice("Claude is asking something in the terminal: answer it there first, then dictate.", offer: false))
        case .draft:
            end(.notice("Claude's prompt box in the terminal already has text: send or clear it there first, then dictate.", offer: false))
        case .empty:
            baseline = ClaudeVoiceScreen.signals(screen.text)
            dimBefore = ClaudeVoiceScreen.prompt(screen).dim
            // Out of focus (the composer has it), Claude draws no level cursor: told it has focus, it does. Only a
            // program that asked for focus events gets it; to any other it would be Esc and typed text.
            if screen.focusEvents == true, session.focusIn() { focusSent = true }
            stage = .holding
            started = now()
            guard space() else { return }
            _ = schedule(Self.firstRepeatWithin) { [weak self] in self?.beginRepeats() }
            readSoon(after: Self.holdReadEvery)
        }
    }

    /// One Space; false (and the run over) when it couldn't go out.
    private func space() -> Bool {
        guard session.keys([Self.space]) else {
            end(.notice("The keys didn't reach the session; nothing was dictated.", offer: false))
            return false
        }
        spaces += 1
        return true
    }

    private func beginRepeats() {
        guard !repeating, stage == .holding, !released, !cancelled else { return }
        repeating = true
        repeatSoon()
    }

    /// The repeats, every `repeatEvery` while held, until a read or the release stops them (`stopHolding`).
    private func repeatSoon() {
        stopSpaces = schedule(Self.repeatEvery) { [weak self] in
            guard let self, self.stage == .holding, !self.released, !self.cancelled, self.stopSpaces != nil else { return }
            guard self.space() else { return }
            self.repeatSoon()
        }
    }

    /// No more Spaces; once some went, End follows the last at once (`disarm`), before anything else the run sends.
    private func stopHolding() {
        stopSpaces?()
        stopSpaces = nil
        guard spaces > 0, !disarmed, !cancelled else { return }
        disarmed = true
        _ = session.keys(Self.disarm)
    }

    private func readSoon(after delay: TimeInterval = ClaudeVoiceRun.readEvery) {
        stopReads?()
        stopReads = schedule(delay) { [weak self] in
            guard let self, self.stage != .done else { return }
            self.session.screen { [weak self] screen in self?.read(screen) }
        }
    }

    private func read(_ screen: LeadDelivery.Screen?) {
        switch stage {
        case .holding: holding(screen)
        case .finishing: finishing(screen)
        case .clearing: clearing(screen)
        case .checking, .done: return
        }
        if stage != .done { readSoon(after: stage == .holding ? Self.holdReadEvery : Self.readEvery) }
    }

    private func holding(_ screen: LeadDelivery.Screen?) {
        guard let screen else { return timedOut() }
        if let signal = ClaudeVoiceScreen.new(ClaudeVoiceScreen.signals(screen.text), since: baseline).first(where: { $0 != .enabled }) {
            return tidy { [weak self] in self?.end(.notice(signal.notice ?? Self.didntStart, offer: signal.offersTurnOn)) }
        }
        let shown = ClaudeVoiceScreen.seen(screen, sent: spaces, dimBefore: dimBefore)
        note(shown, screen)
        switch shown {
        case .tap:
            // Never let tap mode run: its next tap sends.
            stopSpaces?()
            stopSpaces = nil
            _ = session.keys([Self.escape])
            return tidy { [weak self] in self?.end(.notice(Self.tapMode, offer: true)) }
        case .recording:
            if !listening {
                listening = true
                onListening()
            }
            recordingShown = true
            doubting = false
            watch(screen)
        case .heard where !recordingShown, .processing:
            // Words heard with nothing to say it still records (no footer, no level cursor): it does, but they stay dim
            // while it processes too, when a Space could be typed or the push that sends. So the hold stops here, and
            // what was heard is waited for. Processing: it stopped by itself.
            if !listening {
                listening = true
                onListening()
            }
            watch(screen)
            return finishing()
        case .heard, .warming, .typed, .nothing:
            if listening {
                // Claude stopped listening by itself: twice in a row (one read may land mid-redraw), it's over; the
                // Spaces stop and its transcript is waited for.
                if doubting {
                    return finishing()
                }
                doubting = true
            }
        }
        switch LeadDelivery.box(in: screen) {
        case .draft(let draft) where !listening && !ClaudeVoiceScreen.meterOnly(draft):
            // Not spaces: someone typed in the terminal. Nothing of theirs is touched.
            return end(.notice(Self.typedMeanwhile, offer: false))
        case .dialog:
            if listening { _ = session.keys([Self.escape]) }
            return end(.notice("Claude opened a question in the terminal: answer it there first, then dictate.", offer: false))
        case .draft, .empty:
            break
        }
        beginRepeats()
        timedOut()
    }

    private func note(_ shown: ClaudeVoiceScreen.Seen, _ screen: LeadDelivery.Screen) {
        if seen.last != shown { seen.append(shown) }
        spacesShown = ClaudeVoiceScreen.prompt(screen).spaces ?? 0
    }

    /// No recording by the end of the wait: off when the last read showed its Spaces typed and kept (more than a warmup
    /// leaves), else unclear, with no offer to turn it on. Either way the spaces that went in go.
    private func timedOut() {
        guard stage == .holding, !listening, now().timeIntervalSince(started) >= Self.startWithin else { return }
        let last = seen.last ?? .nothing
        let off = last == .typed && spacesShown > ClaudeVoiceScreen.warmupTyped
        Breadcrumbs.shared.note("dictation: Claude's didn't start (\(off ? "off" : "unclear")): seen \(seen.suffix(6).map(\.rawValue).joined(separator: " → ")) after \(spaces) Spaces")
        tidy { [weak self] in self?.end(off ? .notice(Self.didntStart, offer: true) : .notice(Self.unclear(last), offer: false)) }
    }

    /// The spaces that went in while Claude wasn't listening go (⌃U), once the box shows nothing else; if Claude is
    /// listening after all (the release came before a read saw it), its transcript is waited for instead.
    private func tidy(then done: @escaping () -> Void) {
        stopHolding()
        let stage = self.stage
        self.stage = .done
        stopReads?()
        session.screen { [weak self] screen in
            guard let self else { return }
            if let screen, stage == .holding, !self.cancelled,
               ClaudeVoiceScreen.seen(screen, sent: self.spaces, dimBefore: self.dimBefore) == .recording {
                self.stage = .holding
                self.listening = true
                self.onListening()
                return self.finishing()
            }
            if let screen, self.spaces > 0, LeadDelivery.box(in: screen) == .empty { _ = self.session.keys([Self.killLine]) }
            self.stage = stage
            done()
        }
    }

    // MARK: Finishing

    private func finishing() {
        stopHolding()
        stage = .finishing
        finishBy = now().addingTimeInterval(Self.finishWithin)
        readSoon()
    }

    private func finishing(_ screen: LeadDelivery.Screen?) {
        if let screen {
            if let signal = ClaudeVoiceScreen.new(ClaudeVoiceScreen.signals(screen.text), since: baseline).first(where: { $0 != .enabled }) {
                return end(cancelled ? .cancelled : .notice(signal.notice ?? Self.didntStart, offer: signal.offersTurnOn))
            }
            // Still recording or processing (its footer, or its level cursor): the transcript isn't in yet.
            let footer = ClaudeVoiceScreen.footer(screen.text)
            switch footer == .none && ClaudeVoiceScreen.prompt(screen).meter ? .listening : footer {
            case .listening, .warming, .tap, .processing:
                lastDraft = nil
                watch(screen)
            case .none:
                switch LeadDelivery.box(in: screen) {
                case .draft(let draft) where ClaudeVoiceScreen.meterOnly(draft):
                    lastDraft = nil
                case .draft(let draft):
                    steady = draft == lastDraft ? steady + 1 : 1
                    lastDraft = draft
                    if steady >= Self.steadyReads { return take(draft) }
                case .empty:
                    lastDraft = nil
                case .dialog:
                    return end(cancelled ? .cancelled
                               : .notice("Claude opened a question before its dictation was written; whatever it wrote stays in the terminal.", offer: false))
                }
            }
        }
        if now() >= finishBy { end(cancelled ? .cancelled : .notice("Claude's dictation gave no text.", offer: false)) }
    }

    /// While Claude records: the words it shows dim, and whether anything not dim (typed in the terminal) showed too.
    private func watch(_ screen: LeadDelivery.Screen) {
        guard screen.runs != nil else { return }
        // Claude's recording-level cursor (a coloured bar glyph) isn't typed.
        if case .draft(let draft) = LeadDelivery.box(in: screen), !ClaudeVoiceScreen.meterOnly(draft) { typed = true }
        if let dim = LeadDelivery.dimText(in: screen), !dim.isEmpty { live = dim }
    }

    /// The same text a few reads in a row: Claude is done writing it. Out of its box with ⌃U, if it's Claude's: nothing
    /// was typed while it recorded, and it starts as what it heard (what's typed after the release isn't).
    private func take(_ draft: String) {
        guard !typed, ClaudeVoiceScreen.grew(ClaudeVoiceScreen.line(draft), from: live) else {
            return end(cancelled ? .cancelled : .notice(Self.typedMeanwhile, offer: false))
        }
        taken = (draft, ClaudeVoiceScreen.line(draft))
        stage = .clearing
        clearSent = 0
        clearRead = 0
        kill()
    }

    private func kill() {
        guard clearSent < Self.clearKeys, session.keys([Self.killLine]) else { return }
        clearSent += 1
    }

    private func clearing(_ screen: LeadDelivery.Screen?) {
        guard let taken else { return }
        clearRead += 1
        let squeezed = { (text: String) in text.filter { !$0.isWhitespace } }
        switch screen.map(LeadDelivery.box(in:)) {
        case .empty?:
            return end(cancelled ? .cancelled : .text(taken.text))
        case .draft(let draft)? where ClaudeVoiceScreen.meterOnly(draft):
            return end(cancelled ? .cancelled : .text(taken.text))
        case .draft(let draft)? where squeezed(taken.shown).hasPrefix(squeezed(draft)):
            // Not redrawn yet, or a line left (⌃U takes one line at a time).
            if draft != taken.shown || clearRead % 3 == 0 { kill() }
        case .draft?, .dialog?:
            // Out of the box, and something else in it now: ours is handed over, theirs is left alone.
            return end(cancelled ? .cancelled : .text(taken.text))
        case nil:
            break
        }
        if clearRead >= Self.clearReads {
            end(.notice("Claude's prompt box kept the dictated text; it's still there in the terminal.", offer: false))
        }
    }

    private func end(_ outcome: Outcome) {
        guard stage != .done else { return }
        stage = .done
        stopSpaces?()
        stopSpaces = nil
        if focusSent {
            focusSent = false
            session.focusBack()
        }
        if let id = session.id { Self.busy.remove(id) }
        stopReads?()
        stopReads = nil
        finish(outcome)
    }
}
