import Foundation
import VibeCore

/// How long and how big a dictation may be, on the Mac and from the phone.
enum DictationLimits {
    /// A recording stops by itself here.
    static let maxDuration: TimeInterval = 120
    /// Shorter than this, nothing was said: not sent.
    static let minDuration: TimeInterval = 0.3
    /// The most the phone may post (its recorder asks for 32 kbit/s, about 480 KB in 2 minutes; this leaves room for a
    /// browser that records at its own rate).
    static let phoneMaxBytes = 4 * 1024 * 1024
    /// Space held alone in the box this long starts dictation (a tap, or typing, comes up well before).
    static let spaceHold: TimeInterval = 0.4
}

/// Push to talk in the Mac's composer: hold the mic button (or ⌥Space in the box) to record, let go to have it
/// transcribed; the text lands at the composer's cursor for you to read, and is never sent by itself. A Claude Code
/// session in the window dictates through Claude's own /voice (`ClaudeVoiceRun`: your claude.ai sign-in, no key);
/// any other (Codex, a Terminal tab) records here and has OpenAI transcribe it with your key, and the first such press
/// on this Mac shows a one-time note that the audio goes to OpenAI instead of recording. Main thread.
///
/// Each composer (keyed by its row, one per session) has its own run, notice and cancel: while one waits for its text
/// another dictates. Only recording is one at a time (one microphone): a press in another composer ends the recording
/// under way first, as letting go would, so its words still land in its own box.
final class DictationController: ObservableObject, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case recording(rowID: String)
        case transcribing(rowID: String)
    }

    enum KeyState: Equatable {
        case unknown, saved, missing
    }

    /// One line under a composer's box.
    struct Notice: Equatable {
        var rowID: String
        var text: String
        /// Offers Open Settings (no key, or a key OpenAI refused).
        var settings = false
        /// Offers to turn on Claude's dictation in the session (`/voice hold`).
        var turnOn = false
        /// Offers Open Privacy Settings (the microphone's).
        var privacy = false
        /// News, not a failure (said in grey).
        var info = false
    }

    /// A transcript waiting for its composer to put it at the cursor: numbered, so it goes in once.
    struct Delivery: Equatable {
        var serial: Int
        var text: String
    }

    /// A composer's dictation under way, as its views show it.
    struct Run: Equatable {
        /// Recording or transcribing (never idle: a composer with none has no run).
        var phase: Phase
        /// Through Claude's /voice (else OpenAI's).
        var claude: Bool
        /// Claude says it's listening.
        var listening = false
    }

    static let privacyNotedKey = "dictationPrivacyNoted"
    static let modelKey = "dictationModel"
    static let shortcut = "⌥Space"
    static let holdSpaceKey = "dictationHoldSpace"
    static let silenceKey = "dictationSilenceMac"

    /// The composers' runs under way, by row.
    @Published private(set) var runs: [String: Run] = [:] { didSet { syncSilence() } }
    @Published private(set) var keyState: KeyState = .unknown
    /// The line under each composer's box, by row.
    @Published private(set) var notices: [String: Notice] = [:]
    /// The composer showing the one-time note about OpenAI.
    @Published private(set) var privacyNoteFor: String?
    @Published private(set) var deliveries: [String: Delivery] = [:]
    @Published var model: String { didSet { defaults.set(model, forKey: Self.modelKey) } }
    /// Settings: holding Space alone in the box dictates too, as ⌥Space does (on at first).
    @Published var holdSpace: Bool { didSet { defaults.set(holdSpace, forKey: Self.holdSpaceKey) } }
    /// Settings: the Mac's sound is silenced while a composer records, and put back after (on at first).
    @Published var silenceMac: Bool {
        didSet {
            defaults.set(silenceMac, forKey: Self.silenceKey)
            syncSilence()
        }
    }
    /// Settings: a key found in your shell or Codex's file, offered for import (nil: none, or not looked).
    @Published private(set) var found: FoundOpenAIKey?
    @Published private(set) var keyNotice: String?
    /// Opens Settings › General (the composer's link when a key is needed).
    var openSettings: () -> Void = {}
    /// Opens System Settings › Privacy & Security › Microphone.
    var openPrivacy: () -> Void = { SystemMicrophone.openSettings() }
    /// Said when VibeSwitcher may not use the microphone (macOS's answer, or Claude's own messages about it).
    static let microphoneNotice = "VibeSwitcher may not use the microphone, or hears nothing from it: allow VibeSwitcher in System Settings › Privacy & Security › Microphone, and check the input in Sound."
    /// The Claude Code session a composer's dictation goes through (its /voice), when it's one the window can type into;
    /// nil: OpenAI's.
    var claudeSession: (String) -> ClaudeVoiceSession? = { _ in nil }
    /// Claude's settings for a session's folder as dictation reads them (never writes them); off the main thread.
    var claudeSettings: @Sendable (String?) -> ClaudeVoiceSettings = { ClaudeVoiceSettings.read(folder: $0) }
    /// The composers whose sessions are turning Claude's dictation on (`/voice hold` typed, its answer read).
    @Published private(set) var turningOn: Set<String> = []

    private let keyStore: SecretStore
    private let recorder: DictationRecorder
    private let microphone: MicrophoneAuthorizer
    /// Silences the Mac's sound output while a composer records (nil: never; the sandbox, and tests not about it).
    private let silencer: OutputSilencer?
    /// Inside `steadySilence`: the silence is left as it is until the outermost one ends.
    private var steadying = 0
    /// macOS was asked about the microphone (once, at the first press).
    private var askedMicrophone = false
    private let transcription: OpenAITranscription
    private let defaults: UserDefaults
    private let findKey: @Sendable () -> FoundOpenAIKey?
    /// Runs blocking work (the Keychain, the shell, git) away from the main thread; tests run it as it comes.
    private let background: (@escaping @Sendable () -> Void) -> Void
    /// Calls back after a delay (the 2-minute limit); returns what cancels it. Tests give their own clock.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    /// The composer whose mic (button or key) is held down now: one at a time.
    private(set) var held: String?
    /// What each run keeps that its views don't show.
    private final class Work {
        var claudeRun: ClaudeVoiceRun?
        var cancelLimit: (() -> Void)?
        var vocabulary: (@Sendable () -> String)?
        /// Called once its Claude run has ended (a message sent over it goes then): true when Claude's box is as it
        /// was, false when the run said something's left there.
        var afterClaude: [(Bool) -> Void] = []
    }
    private var work: [String: Work] = [:]
    private var serial = 0
    /// The clock Claude's runs keep (tests give their own).
    private let now: () -> Date
    /// A Claude run in this launch heard something (its level cursor coloured, or text taken): the microphone works, so
    /// a later run that hears nothing isn't said to be the microphone's doing.
    private(set) var claudeHeard = false
    /// Called each time a run ends (tests wait on it).
    var onIdle: (() -> Void)?

    init(keyStore: SecretStore, recorder: DictationRecorder, microphone: MicrophoneAuthorizer, silencer: OutputSilencer? = nil,
         transcription: OpenAITranscription = OpenAITranscription(),
         defaults: UserDefaults = .standard, findKey: @escaping @Sendable () -> FoundOpenAIKey? = { DictationKey.findLive() },
         background: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = DictationController.after,
         now: @escaping () -> Date = Date.init) {
        self.keyStore = keyStore
        self.recorder = recorder
        self.microphone = microphone
        self.silencer = silencer
        self.transcription = transcription
        self.defaults = defaults
        self.findKey = findKey
        self.background = background
        self.schedule = schedule
        self.now = now
        let saved = defaults.string(forKey: Self.modelKey) ?? ""
        model = OpenAITranscription.models.contains(saved) ? saved : OpenAITranscription.defaultModel
        holdSpace = defaults.object(forKey: Self.holdSpaceKey) as? Bool ?? true
        silenceMac = defaults.object(forKey: Self.silenceKey) as? Bool ?? true
    }

    static func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    var privacyNoted: Bool { defaults.bool(forKey: Self.privacyNotedKey) }

    func phase(_ rowID: String) -> Phase { runs[rowID]?.phase ?? .idle }
    func isRecording(_ rowID: String) -> Bool { phase(rowID) == .recording(rowID: rowID) }
    func isTranscribing(_ rowID: String) -> Bool { phase(rowID) == .transcribing(rowID: rowID) }
    /// Recording or transcribing for that composer (Esc there cancels it).
    func isBusy(_ rowID: String) -> Bool { runs[rowID] != nil }
    /// That composer's run goes through Claude's /voice.
    func isClaude(_ rowID: String) -> Bool { runs[rowID]?.claude == true }
    /// Claude says it's listening to that composer's run.
    func isListening(_ rowID: String) -> Bool { runs[rowID]?.listening == true }

    /// The composer whose recording is under way (one at a time: one microphone).
    private var recordingRow: String? { runs.first { $0.value.phase == .recording(rowID: $0.key) }?.key }

    /// The keys that dictate in the box, as said in tooltips and notices.
    var shortcuts: String { holdSpace ? "Space or \(Self.shortcut)" : Self.shortcut }

    /// Whether holding Space in `rowID`'s box may start a run now: it's on, and nothing else is under way there
    /// (otherwise the spaces stay typed).
    func canHoldSpace(_ rowID: String) -> Bool { holdSpace && runs[rowID] == nil && !turningOn.contains(rowID) }

    /// Whether `rowID`'s dictation goes through Claude's /voice: a Claude Code session the window can type into.
    func usesClaude(_ rowID: String, agent: Agent?) -> Bool { route(rowID, agent: agent) != nil }

    private func route(_ rowID: String, agent: Agent?) -> ClaudeVoiceSession? {
        agent == .claude ? claudeSession(rowID) : nil
    }

    // MARK: Push to talk

    /// The button or ⌥Space went down in `rowID`'s composer, whose session runs `agent`. `vocabulary` makes OpenAI's
    /// prompt (run off the main thread; Claude takes the project's and branch's names itself). A recording in another
    /// composer ends first, as its release would.
    func press(_ rowID: String, agent: Agent? = nil, vocabulary: @escaping @Sendable () -> String) {
        steadySilence { pressNow(rowID, agent: agent, vocabulary: vocabulary) }
    }

    private func pressNow(_ rowID: String, agent: Agent?, vocabulary: @escaping @Sendable () -> String) {
        guard runs[rowID] == nil, !turningOn.contains(rowID) else { return }
        notices[rowID] = nil
        // The microphone first, for either: macOS asks about VibeSwitcher for a session's Claude too.
        switch microphone.status {
        case .allowed:
            break
        case .denied:
            return microphoneDenied(rowID)
        case .undetermined:
            // Asked once, at this first press; still held when it's allowed, it goes on.
            guard !askedMicrophone else { return microphoneDenied(rowID) }
            askedMicrophone = true
            held = rowID
            return microphone.request { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    if self.held == rowID { self.held = nil }
                    return self.microphoneDenied(rowID)
                }
                if self.held == rowID { self.press(rowID, agent: agent, vocabulary: vocabulary) }
            }
        }
        if let session = route(rowID, agent: agent) { return pressClaude(rowID, session) }
        if keyState == .missing { return needKey(rowID) }
        guard privacyNoted else {
            privacyNoteFor = rowID
            return
        }
        endOtherRecording(rowID)
        held = rowID
        recorder.permission { [weak self] allowed in
            self?.steadySilence { self?.recordingAllowed(allowed, rowID, vocabulary: vocabulary) }
        }
    }

    /// macOS answered about the microphone for `rowID`'s press: it records, unless let go or pressed elsewhere since.
    private func recordingAllowed(_ allowed: Bool, _ rowID: String, vocabulary: @escaping @Sendable () -> String) {
        guard allowed else {
            if held == rowID { held = nil }
            return microphoneDenied(rowID)
        }
        // Let go before macOS answered (its first-time question), or another composer pressed since: nothing to
        // record.
        guard held == rowID, runs[rowID] == nil else { return }
        endOtherRecording(rowID)
        do {
            try recorder.start()
        } catch {
            held = nil
            notices[rowID] = Notice(rowID: rowID, text: "The microphone couldn't be started.")
            return
        }
        let work = Work()
        work.vocabulary = vocabulary
        work.cancelLimit = schedule(DictationLimits.maxDuration) { [weak self] in self?.stop(rowID, limitReached: true) }
        begin(rowID, Run(phase: .recording(rowID: rowID), claude: false), work)
    }

    /// The button or ⌥Space came up in `rowID`'s composer: its recording goes to OpenAI, or Claude finishes its
    /// transcript. Nothing when that composer isn't recording (another press ended it already).
    func release(_ rowID: String) {
        if held == rowID { held = nil }
        guard isRecording(rowID) else { return }
        guard isClaude(rowID) else { return stop(rowID, limitReached: false) }
        runs[rowID]?.phase = .transcribing(rowID: rowID)
        // No run yet (Claude's settings are being read): it's let go as it starts.
        work[rowID]?.claudeRun?.release()
    }

    /// Esc or the ✕ in `rowID`'s composer: its recording is dropped (Claude's: stopped with its own cancel, held,
    /// waiting or processing), nothing lands in the box. Other composers' runs go on.
    func cancel(_ rowID: String, _ reason: ClaudeVoiceRun.CancelReason = .escape) {
        if held == rowID { held = nil }
        guard let run = runs[rowID] else { return }
        if run.claude {
            if let claudeRun = work[rowID]?.claudeRun { return claudeRun.cancel(reason) }
            // Its settings still being read: nothing went into the session.
            return finishClaude(rowID, .cancelled)
        }
        guard case .recording = run.phase else { return }
        recorder.cancel()
        idle(rowID)
    }

    /// The one-time note was read: from now on a press records.
    func acknowledgePrivacy() {
        defaults.set(true, forKey: Self.privacyNotedKey)
        privacyNoteFor = nil
    }

    func dismissNotice(_ rowID: String) { notices[rowID] = nil }

    /// The composer put `serial`'s text in (or the box went away with it shown): it's not offered again.
    func delivered(_ rowID: String, serial: Int) {
        if deliveries[rowID]?.serial == serial { deliveries[rowID] = nil }
    }

    /// One microphone: a recording in a composer other than `rowID`'s ends as letting go would, its words still
    /// going to its own box.
    private func endOtherRecording(_ rowID: String) {
        guard let other = recordingRow, other != rowID else { return }
        Breadcrumbs.shared.note("dictation: a press in another composer ended the recording under way")
        release(other)
    }

    /// Runs `body` with the Mac's sound left as it is until it ends: a recording that ends there for another to begin
    /// (a press in another composer) doesn't bring the sound back between the two.
    private func steadySilence(_ body: () -> Void) {
        steadying += 1
        defer {
            steadying -= 1
            syncSilence()
        }
        body()
    }

    /// The Mac's sound silenced while a composer records (and the setting's on), put back once none does.
    private func syncSilence() {
        guard let silencer, steadying == 0 else { return }
        silencer.set(holders: silenceMac ? Set(runs.keys.filter { isRecording($0) }) : [])
    }

    private func begin(_ rowID: String, _ run: Run, _ work: Work) {
        self.work[rowID] = work
        runs[rowID] = run
    }

    private func stop(_ rowID: String, limitReached: Bool) {
        guard isRecording(rowID), !isClaude(rowID), let work = work[rowID] else { return }
        work.cancelLimit?()
        work.cancelLimit = nil
        let audio = recorder.stop()
        let vocabulary = work.vocabulary ?? { "" }
        work.vocabulary = nil
        guard let audio, audio.duration >= DictationLimits.minDuration else {
            notices[rowID] = Notice(rowID: rowID, text: "Nothing was recorded: hold the mic button (or \(shortcuts)) while you speak.")
            return idle(rowID)
        }
        if limitReached { notices[rowID] = Notice(rowID: rowID, text: "Stopped at 2 minutes, the most one dictation takes.") }
        runs[rowID]?.phase = .transcribing(rowID: rowID)
        let (keyStore, transcription, model) = (keyStore, transcription, model)
        background { [weak self] in
            let key = keyStore.read()
            let prompt = vocabulary()
            Task.detached(priority: .userInitiated) {
                let result: Result<String, OpenAITranscription.Failure>
                do {
                    result = .success(try await transcription.transcribe(audio, model: model, prompt: prompt, key: key))
                } catch {
                    result = .failure(error as? OpenAITranscription.Failure ?? .unreadable)
                }
                DispatchQueue.main.async { self?.finish(result, rowID: rowID) }
            }
        }
    }

    private func finish(_ result: Result<String, OpenAITranscription.Failure>, rowID: String) {
        switch result {
        case .success(let text):
            deliver(text, to: rowID)
            if keyState != .saved { keyState = .saved }
        case .failure(.noKey):
            keyState = .missing
            needKey(rowID)
        case .failure(let failure):
            notices[rowID] = Notice(rowID: rowID, text: failure.notice, settings: failure == .status(401))
        }
        idle(rowID)
    }

    private func deliver(_ text: String, to rowID: String) {
        serial += 1
        let before = deliveries[rowID]?.text
        deliveries[rowID] = Delivery(serial: serial, text: before.map { $0 + " " + text } ?? text)
    }

    /// `rowID`'s run is over.
    private func idle(_ rowID: String) {
        work[rowID]?.cancelLimit?()
        work[rowID] = nil
        runs[rowID] = nil
        onIdle?()
    }

    // MARK: Claude's /voice

    /// Claude's settings first (tap mode and autoSubmit send by themselves: not used), then the run.
    private func pressClaude(_ rowID: String, _ session: ClaudeVoiceSession) {
        endOtherRecording(rowID)
        held = rowID
        begin(rowID, Run(phase: .recording(rowID: rowID), claude: true), Work())
        let (read, folder) = (claudeSettings, session.folder)
        background { [weak self] in
            let settings = read(folder)
            DispatchQueue.main.async { self?.startClaude(rowID, session, settings) }
        }
    }

    private func startClaude(_ rowID: String, _ session: ClaudeVoiceSession, _ settings: ClaudeVoiceSettings) {
        guard isClaude(rowID), let work = work[rowID], work.claudeRun == nil else { return }
        if let refusal = settings.refusal {
            Breadcrumbs.shared.note("dictation: Claude's not started, its settings: \(refusal.text)")
            return finishClaude(rowID, .notice(refusal.text, offer: refusal.offer))
        }
        let run = ClaudeVoiceRun(session: session, schedule: schedule, now: now, heardBefore: claudeHeard,
                                 onListening: { [weak self] in self?.runs[rowID]?.listening = true },
                                 onHeard: { [weak self] in self?.claudeHeard = true },
                                 finish: { [weak self] outcome in self?.finishClaude(rowID, outcome) })
        work.claudeRun = run
        work.cancelLimit = schedule(DictationLimits.maxDuration) { [weak self] in
            guard let self, self.work[rowID]?.claudeRun === run, self.isRecording(rowID) else { return }
            self.notices[rowID] = Notice(rowID: rowID, text: "Stopped at 2 minutes, the most one dictation takes.", info: true)
            self.release(rowID)
        }
        run.start()
        // Let go (or ended by a press elsewhere) while the settings were read.
        if held != rowID { runs[rowID]?.phase = .transcribing(rowID: rowID) }
        if !isRecording(rowID) { run.release() }
    }

    private func finishClaude(_ rowID: String, _ outcome: ClaudeVoiceRun.Outcome) {
        guard let work = work[rowID] else { return }
        switch outcome {
        case .text(let text):
            claudeHeard = true
            deliver(text, to: rowID)
        case .notice(let text, let offer):
            notices[rowID] = Notice(rowID: rowID, text: text, turnOn: offer, privacy: text == Self.microphoneNotice || text == ClaudeVoiceRun.heardNothing)
        case .cancelled:
            break
        }
        if held == rowID { held = nil }
        idle(rowID)
        let clean: Bool
        if case .notice = outcome { clean = false } else { clean = true }
        work.afterClaude.forEach { $0(clean) }
    }

    /// A message sent from the composer into `session` while a Claude dictation goes into it: the dictation is
    /// cancelled, and `then` runs once it's stopped, so the message never mixes with what Claude might still write: true
    /// when its box is as it was, false when the run left something there (the message mustn't go onto it). False when no
    /// dictation of this controller's goes into that session.
    func override(session: UUID, then: @escaping (Bool) -> Void) -> Bool {
        guard let entry = work.first(where: { $0.value.claudeRun?.sessionID == session }), let claudeRun = entry.value.claudeRun
        else { return false }
        if held == entry.key { held = nil }
        entry.value.afterClaude.append(then)
        claudeRun.cancel(.send)
        return true
    }

    /// After your click on the notice's offer: `/voice hold` typed into the session (only with its prompt box empty),
    /// and what Claude answers said under the box. Claude's settings and keys are its own: never edited from here.
    func turnOnClaude(_ rowID: String) {
        guard runs[rowID] == nil, !turningOn.contains(rowID) else { return }
        guard let session = claudeSession(rowID) else {
            notices[rowID] = Notice(rowID: rowID, text: "This session can't be typed into from here: run /voice hold in its terminal.")
            return
        }
        turningOn.insert(rowID)
        notices[rowID] = Notice(rowID: rowID, text: "Turning on Claude's dictation…", info: true)
        session.screen { [weak self] screen in
            guard let self, self.turningOn.contains(rowID) else { return }
            guard let screen, LeadDelivery.box(in: screen) == .empty else {
                return self.turnedOn(rowID, Notice(rowID: rowID, text: "Claude's prompt box in the terminal isn't empty: clear it there, then turn dictation on."))
            }
            let before = ClaudeVoiceScreen.signals(screen.text)
            let conversation = ClaudeVoiceScreen.conversation(screen.text)
            guard session.command(Self.turnOnCommand) else {
                return self.turnedOn(rowID, Notice(rowID: rowID, text: "/voice hold couldn't be typed into the session."))
            }
            Breadcrumbs.shared.note("dictation: turning on Claude's (\(Self.turnOnCommand) typed)")
            self.watchTurnOn(rowID, session, since: before, conversation: conversation, until: Date().addingTimeInterval(Self.turnOnWait))
        }
    }

    static let turnOnCommand = "/voice hold"
    /// How long Claude may take to say what came of `/voice hold` (it checks the microphone first).
    static let turnOnWait: TimeInterval = 8

    /// Claude's answer to `/voice hold`: its first dictation message after the command's newest echo once the
    /// conversation changed since the click (`conversation`), or one shown more often than at the click.
    private func watchTurnOn(_ rowID: String, _ session: ClaudeVoiceSession, since before: [ClaudeVoiceScreen.Signal: Int],
                             conversation: [String], until deadline: Date) {
        _ = schedule(ClaudeVoiceRun.readEvery * 2) { [weak self] in
            session.screen { [weak self] screen in
                guard let self, self.turningOn.contains(rowID) else { return }
                if let screen, let signal = ClaudeVoiceScreen.answer(to: Self.turnOnCommand, in: screen.text, before: conversation)
                    ?? ClaudeVoiceScreen.new(ClaudeVoiceScreen.signals(screen.text), since: before).first {
                    let notice = signal.notice.map { Notice(rowID: rowID, text: $0) }
                        ?? Notice(rowID: rowID, text: "Claude's dictation is on: hold the mic (or \(shortcuts) in the box) and speak.", info: true)
                    return self.turnedOn(rowID, notice)
                }
                guard Date() < deadline else {
                    return self.turnedOn(rowID, Notice(rowID: rowID, text: "Claude didn't say whether its dictation is on: have a look at the terminal."))
                }
                self.watchTurnOn(rowID, session, since: before, conversation: conversation, until: deadline)
            }
        }
    }

    private func turnedOn(_ rowID: String, _ notice: Notice) {
        Breadcrumbs.shared.note("dictation: turning on Claude's ended: \(notice.text)")
        turningOn.remove(rowID)
        notices[rowID] = notice
    }

    private func microphoneDenied(_ rowID: String) {
        Breadcrumbs.shared.note("dictation: not started, macOS says VibeSwitcher may not use the microphone")
        notices[rowID] = Notice(rowID: rowID, text: Self.microphoneNotice, privacy: true)
    }

    private func needKey(_ rowID: String) {
        notices[rowID] = Notice(rowID: rowID, text: OpenAITranscription.Failure.noKey.notice, settings: true)
    }

    // MARK: The key

    /// Whether a key is saved (the mic button says so when none is). Off the main thread: the Keychain may ask first.
    func checkKey() {
        let keyStore = keyStore
        background { [weak self] in
            let saved = keyStore.read()?.isEmpty == false
            DispatchQueue.main.async { self?.keyState = saved ? .saved : .missing }
        }
    }

    /// Settings opened: whether a key is saved, and, when none is, a key in your shell or Codex's file to offer.
    func lookForKeys() {
        let (keyStore, findKey) = (keyStore, findKey)
        background { [weak self] in
            let saved = keyStore.read()?.isEmpty == false
            let found = saved ? nil : findKey()
            DispatchQueue.main.async {
                self?.keyState = saved ? .saved : .missing
                self?.found = found
            }
        }
    }

    /// Saves a typed key in the Keychain (nil: removes the saved one). One that isn't an OpenAI key isn't saved.
    func saveKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, DictationKey.usable(trimmed) == nil {
            keyNotice = "That doesn't look like an OpenAI API key (they start with sk-); nothing was saved."
            return
        }
        update(trimmed?.isEmpty == false ? trimmed : nil)
    }

    /// Import, after you confirmed it: the key found in your shell or Codex's file, saved as if typed.
    func importFound() {
        guard let found else { return }
        self.found = nil
        update(found.key)
    }

    private func update(_ value: String?) {
        let keyStore = keyStore
        background { [weak self] in
            let ok = keyStore.write(value)
            let saved = keyStore.read()?.isEmpty == false
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyState = saved ? .saved : .missing
                self.keyNotice = ok ? nil : "The Keychain didn't take it; nothing was saved."
                if saved { self.notices = self.notices.filter { !$0.value.settings } }
            }
        }
    }
}
