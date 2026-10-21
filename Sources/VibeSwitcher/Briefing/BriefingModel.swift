import Foundation
import VibeCore

/// The Brief me button's state: pressing it writes a thirty-second briefing of what happened lately across the
/// projects VibeSwitcher leads (`Briefing`), shows it, and reads it aloud, through ElevenLabs when a key is saved in
/// Settings, else with the Mac's voice. Pressing it again stops it. Nothing leaves the Mac but on a press (Brief me,
/// Play, Test voice): the briefing's notes go to headless Claude, its text to ElevenLabs when there's a key.
/// Used on the main thread; the writing, the Keychain and ElevenLabs run off it.
///
/// The global model (`.all`) also hands out one per led project (`project(_:)`, Brief me on <project>): the same
/// inputs, key, language and voice, its briefing written from that project alone, and its own 'since' stamp. They
/// share one voice: a briefing that starts stops the one under way, whichever it was.
final class BriefingModel: ObservableObject, @unchecked Sendable {
    enum Phase: Equatable { case idle, writing, speaking }

    /// What it briefs on: every led project, or the one at a root.
    enum Scope: Hashable {
        case all
        case project(root: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The last briefing written (this launch).
    @Published private(set) var briefing: BriefingText?
    /// One line about the voice when it isn't ElevenLabs' though a key is saved (it failed, couldn't play).
    @Published private(set) var voiceNotice: String?
    /// The menu bar's panel closed until the next briefing.
    @Published var panelHidden = false
    /// Counts the window menu's presses: the views that hold the panel open it (`pressFromMenu()`).
    @Published private(set) var revealed = 0
    /// Whether an ElevenLabs key is saved (nil: not looked yet), and what the last save said.
    @Published private(set) var keySaved: Bool?
    @Published private(set) var keyNotice: String?

    /// What the briefing is composed from, taken on the main thread: each led project's board by root, and the sessions.
    struct Snapshot {
        var boards: [String: LeadBoard]
        var sessions: [Session]
    }

    let scope: Scope
    private let snapshot: () -> Snapshot
    private let language: () -> BriefingLanguage
    private let generate: @Sendable (String) -> String?
    private let keyStore: SecretStore
    private let client: ElevenLabs
    private let shared: Shared
    private var voice: BriefingVoice { shared.voice }
    private let defaults: UserDefaults
    private let now: () -> Double

    /// What the global model and its projects' share: the voice, which of them it speaks for, and the projects' models.
    private final class Shared {
        let voice: BriefingVoice
        weak var owner: BriefingModel?
        var projects: [String: BriefingModel] = [:]

        init(voice: BriefingVoice) { self.voice = voice }
    }
    /// ElevenLabs' audio for the last text it read: Play reads it again without another request.
    private var audio: (text: String, data: Data)?
    /// Each press's number: what an earlier one finds when it comes back late is dropped.
    private var run = 0

    static let lastKey = "briefingLastAt"

    /// Where a scope's last briefing time is kept: the global one's as it always was, each project's apart (by its
    /// root), so neither moves the other's 'since'.
    static func lastKey(_ scope: Scope) -> String {
        switch scope {
        case .all: return lastKey
        case .project(let root): return "briefingLastAt.project:" + root
        }
    }

    convenience init(snapshot: @escaping () -> Snapshot, language: @escaping () -> BriefingLanguage, keyStore: SecretStore,
                     generate: @escaping @Sendable (String) -> String? = { ClaudeHeadless.brief($0) }, client: ElevenLabs = ElevenLabs(),
                     voice: BriefingVoice? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.init(scope: .all, snapshot: snapshot, language: language, keyStore: keyStore, generate: generate, client: client,
                  shared: Shared(voice: voice ?? BriefingSpeaker()), defaults: defaults, now: now)
        let shared = shared
        shared.voice.finished = { [weak shared] in
            guard let owner = shared?.owner, owner.phase == .speaking else { return }
            owner.phase = .idle
        }
    }

    private init(scope: Scope, snapshot: @escaping () -> Snapshot, language: @escaping () -> BriefingLanguage, keyStore: SecretStore,
                 generate: @escaping @Sendable (String) -> String?, client: ElevenLabs, shared: Shared, defaults: UserDefaults,
                 now: @escaping () -> Double) {
        self.scope = scope
        self.snapshot = snapshot
        self.language = language
        self.keyStore = keyStore
        self.generate = generate
        self.client = client
        self.shared = shared
        self.defaults = defaults
        self.now = now
    }

    /// Brief me on the project at `root`: the same one each time it's asked for (the global model's; a project's
    /// answers for its own root).
    func project(_ root: String) -> BriefingModel {
        if case .project(root) = scope { return self }
        if let model = shared.projects[root] { return model }
        let model = BriefingModel(scope: .project(root: root), snapshot: snapshot, language: language, keyStore: keyStore,
                                  generate: generate, client: client, shared: shared, defaults: defaults, now: now)
        shared.projects[root] = model
        return model
    }

    /// The project's name (its folder's), for a project's model.
    var projectName: String? {
        guard case .project(let root) = scope else { return nil }
        return (root as NSString).lastPathComponent
    }

    /// When this scope's last briefing was written: the next one covers what's new since (or the last 3 hours, if
    /// longer).
    var lastBriefed: Double? { defaults.object(forKey: Self.lastKey(scope)) as? Double }

    /// Takes the shared voice for this model: the one it spoke for (writing or reading) stops.
    private func claimVoice() {
        if let owner = shared.owner, owner !== self, owner.phase != .idle {
            owner.run += 1
            owner.phase = .idle
            voice.stop()
        }
        shared.owner = self
    }

    // MARK: The button

    /// Brief me: writes and reads one; while it's written or read, stops it.
    func press() {
        switch phase {
        case .writing:
            run += 1
            phase = .idle
        case .speaking: stop()
        case .idle: brief()
        }
    }

    /// The panel's Play / Stop: reads the last briefing again (ElevenLabs' audio kept from the first time), or stops.
    func playOrStop() {
        if phase == .speaking { return stop() }
        guard phase == .idle, let briefing else { return }
        speak(briefing.text, language: briefing.language.code)
    }

    /// Brief Me from the window's menu: presses it, and has the panel shown.
    func pressFromMenu() {
        press()
        panelHidden = false
        revealed += 1
    }

    func stop() {
        run += 1
        if shared.owner === self { voice.stop() }
        phase = .idle
    }

    private func brief() {
        claimVoice()
        run += 1
        let id = run
        phase = .writing
        panelHidden = false
        voiceNotice = nil
        let taken = snapshot()
        let language = language()
        let since = lastBriefed
        let at = now()
        let (scope, generate, keyStore) = (scope, generate, keyStore)
        DispatchQueue.global(qos: .userInitiated).async {
            let input = Self.input(taken, scope: scope, lastBriefed: since, now: at)
            let written = Briefing.write(input, language: language, generate: generate, now: at)
            let key = keyStore.read()
            DispatchQueue.main.async { self.written(written, key: key, run: id) }
        }
    }

    private func written(_ text: BriefingText, key: String?, run id: Int) {
        guard id == run, phase == .writing else { return }
        briefing = text
        defaults.set(text.at, forKey: Self.lastKey(scope))
        start(text.text, language: text.language.code, key: key, run: id)
    }

    /// Reads `text` aloud: the key is read off the main thread first.
    private func speak(_ text: String, language: String) {
        claimVoice()
        run += 1
        let id = run
        voiceNotice = nil
        phase = .speaking
        let keyStore = keyStore
        DispatchQueue.global(qos: .userInitiated).async {
            let key = keyStore.read()
            DispatchQueue.main.async { self.start(text, language: language, key: key, run: id) }
        }
    }

    private func start(_ text: String, language: String, key: String?, run id: Int) {
        guard id == run, shared.owner === self else { return }
        phase = .speaking
        guard let key, !key.isEmpty else { return voice.say(text, language: language) }
        if let audio, audio.text == text, voice.play(audio.data) { return }
        let client = client
        Task.detached {
            let result: Result<Data, ElevenLabs.Failure>
            do { result = .success(try await client.speech(text: text, language: language, key: key)) } catch {
                result = .failure(error as? ElevenLabs.Failure ?? .empty)
            }
            DispatchQueue.main.async { self.spoken(result, text: text, language: language, run: id) }
        }
    }

    /// ElevenLabs answered: its audio plays, or the Mac's voice reads it with a one-line notice why.
    private func spoken(_ result: Result<Data, ElevenLabs.Failure>, text: String, language: String, run id: Int) {
        guard id == run, phase == .speaking, shared.owner === self else { return }
        switch result {
        case .success(let data):
            audio = (text, data)
            if voice.play(data) { return }
            voiceNotice = "ElevenLabs' audio couldn't be played, so the Mac's voice reads it."
        case .failure(let failure):
            voiceNotice = failure.notice
        }
        voice.say(text, language: language)
    }

    // MARK: Settings

    /// Settings › General › Briefing › Test voice: one sentence in the chosen language, through the voice a
    /// briefing would use.
    func testVoice() {
        if phase != .idle { stop() }
        let language = language()
        speak(Self.sample(language), language: Self.sample[language.code] == nil ? "en" : language.code)
    }

    /// Looks whether a key is saved (off the main thread: the Keychain may ask you first).
    func checkKey() {
        let keyStore = keyStore
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = keyStore.read() != nil
            DispatchQueue.main.async { self.keySaved = saved }
        }
    }

    /// Saves the key in the Keychain (nil or empty: removes it).
    func saveKey(_ value: String?) {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyStore = keyStore
        audio = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = keyStore.write(value)
            DispatchQueue.main.async {
                if ok { self.keySaved = value?.isEmpty == false }
                self.keyNotice = ok ? nil : "The Keychain didn't take it; nothing was saved."
            }
        }
    }

    // MARK: Inputs

    /// What a briefing of `scope` is written from: every led project, or the one at a root (its board when it's led
    /// now, else an empty one: its log still says what happened).
    static func input(_ snapshot: Snapshot, scope: Scope, lastBriefed: Double?, now: Double) -> BriefingInput {
        switch scope {
        case .all:
            return Briefing.compose(sources(snapshot.boards), sessions: snapshot.sessions, lastBriefed: lastBriefed, now: now)
        case .project(let root):
            let source = sources([root: snapshot.boards[root] ?? LeadBoard()])[0]
            return Briefing.compose(project: source, sessions: snapshot.sessions, lastBriefed: lastBriefed, now: now)
        }
    }

    /// The newest part of a progress log read (a day's log is a few KB; a long-lived one is cut here).
    static let logTail = 256 * 1024

    /// Each led project as the composer takes it: its folder's name, the tail of its progress log, its board.
    static func sources(_ boards: [String: LeadBoard]) -> [Briefing.Source] {
        boards.map { root, board in
            Briefing.Source(name: (root as NSString).lastPathComponent, progress: tail(BoardStore(root: root).recordPath("progress.md")), board: board)
        }
    }

    static func tail(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(logTail) ? size - UInt64(logTail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Test voice's sentence, in the languages most likely chosen; English for the rest.
    static let sample: [String: String] = [
        "en": "This is how your VibeSwitcher briefing will sound.",
        "es": "Así sonará tu resumen de VibeSwitcher.",
        "ca": "Així sonarà el teu resum de VibeSwitcher.",
        "fr": "Voici comment sonnera votre point VibeSwitcher.",
        "de": "So klingt dein VibeSwitcher-Briefing.",
        "it": "Ecco come suonerà il tuo riepilogo di VibeSwitcher.",
        "pt": "É assim que vai soar o seu resumo do VibeSwitcher.",
        "nl": "Zo klinkt je VibeSwitcher-briefing.",
        "ja": "VibeSwitcherのブリーフィングはこのように聞こえます。",
        "zh": "这就是 VibeSwitcher 简报的声音。",
        "ko": "VibeSwitcher 브리핑은 이렇게 들립니다.",
        "ru": "Так будет звучать ваша сводка VibeSwitcher.",
    ]

    static func sample(_ language: BriefingLanguage) -> String { sample[language.code] ?? sample["en"]! }
}
