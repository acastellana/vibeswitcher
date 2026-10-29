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
}

/// Push to talk in the Mac's composer: hold the mic button (or ⌥Space in the box) to record, let go to have OpenAI
/// transcribe it with your key; the text lands at the composer's cursor for you to read, and is never sent by itself.
/// The first press on this Mac shows a one-time note that the audio goes to OpenAI instead of recording. Main thread.
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
    }

    /// A transcript waiting for its composer to put it at the cursor: numbered, so it goes in once.
    struct Delivery: Equatable {
        var serial: Int
        var text: String
    }

    static let privacyNotedKey = "dictationPrivacyNoted"
    static let modelKey = "dictationModel"
    static let shortcut = "⌥Space"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var keyState: KeyState = .unknown
    @Published private(set) var notice: Notice?
    /// The composer showing the one-time note about OpenAI.
    @Published private(set) var privacyNoteFor: String?
    @Published private(set) var deliveries: [String: Delivery] = [:]
    @Published var model: String { didSet { defaults.set(model, forKey: Self.modelKey) } }
    /// Settings: a key found in your shell or Codex's file, offered for import (nil: none, or not looked).
    @Published private(set) var found: FoundOpenAIKey?
    @Published private(set) var keyNotice: String?
    /// Opens Settings › General (the composer's link when a key is needed).
    var openSettings: () -> Void = {}

    private let keyStore: SecretStore
    private let recorder: DictationRecorder
    private let transcription: OpenAITranscription
    private let defaults: UserDefaults
    private let findKey: @Sendable () -> FoundOpenAIKey?
    /// Runs blocking work (the Keychain, the shell, git) away from the main thread; tests run it as it comes.
    private let background: (@escaping @Sendable () -> Void) -> Void
    /// Calls back after a delay (the 2-minute limit); returns what cancels it. Tests give their own clock.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    private var holding = false
    private var vocabulary: (@Sendable () -> String)?
    private var cancelLimit: (() -> Void)?
    private var serial = 0
    /// Called each time the phase goes back to idle (tests wait on it).
    var onIdle: (() -> Void)?

    init(keyStore: SecretStore, recorder: DictationRecorder, transcription: OpenAITranscription = OpenAITranscription(),
         defaults: UserDefaults = .standard, findKey: @escaping @Sendable () -> FoundOpenAIKey? = { DictationKey.findLive() },
         background: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = DictationController.after) {
        self.keyStore = keyStore
        self.recorder = recorder
        self.transcription = transcription
        self.defaults = defaults
        self.findKey = findKey
        self.background = background
        self.schedule = schedule
        let saved = defaults.string(forKey: Self.modelKey) ?? ""
        model = OpenAITranscription.models.contains(saved) ? saved : OpenAITranscription.defaultModel
    }

    static func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    var privacyNoted: Bool { defaults.bool(forKey: Self.privacyNotedKey) }

    func isRecording(_ rowID: String) -> Bool { phase == .recording(rowID: rowID) }
    func isTranscribing(_ rowID: String) -> Bool { phase == .transcribing(rowID: rowID) }

    // MARK: Push to talk

    /// The button or ⌥Space went down in `rowID`'s composer. `vocabulary` makes the prompt (run off the main thread).
    func press(_ rowID: String, vocabulary: @escaping @Sendable () -> String) {
        guard phase == .idle else { return }
        notice = nil
        if keyState == .missing { return needKey(rowID) }
        guard privacyNoted else {
            privacyNoteFor = rowID
            return
        }
        holding = true
        recorder.permission { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.holding = false
                self.notice = Notice(rowID: rowID, text: "VibeSwitcher may not use the microphone: allow it in System Settings › Privacy & Security › Microphone.")
                return
            }
            // Let go before macOS answered (its first-time question): nothing to record.
            guard self.holding, self.phase == .idle else { return }
            do {
                try self.recorder.start()
            } catch {
                self.holding = false
                self.notice = Notice(rowID: rowID, text: "The microphone couldn't be started.")
                return
            }
            self.vocabulary = vocabulary
            self.phase = .recording(rowID: rowID)
            self.cancelLimit = self.schedule(DictationLimits.maxDuration) { [weak self] in self?.stop(limitReached: true) }
        }
    }

    /// The button or ⌥Space came up: the recording goes to OpenAI.
    func release() {
        holding = false
        stop(limitReached: false)
    }

    /// The one-time note was read: from now on a press records.
    func acknowledgePrivacy() {
        defaults.set(true, forKey: Self.privacyNotedKey)
        privacyNoteFor = nil
    }

    func dismissNotice() { notice = nil }

    /// The composer put `serial`'s text in (or the box went away with it shown): it's not offered again.
    func delivered(_ rowID: String, serial: Int) {
        if deliveries[rowID]?.serial == serial { deliveries[rowID] = nil }
    }

    private func stop(limitReached: Bool) {
        guard case .recording(let rowID) = phase else { return }
        cancelLimit?()
        cancelLimit = nil
        let audio = recorder.stop()
        let vocabulary = vocabulary ?? { "" }
        self.vocabulary = nil
        guard let audio, audio.duration >= DictationLimits.minDuration else {
            notice = Notice(rowID: rowID, text: "Nothing was recorded: hold the mic button (or \(Self.shortcut)) while you speak.")
            return idle()
        }
        if limitReached { notice = Notice(rowID: rowID, text: "Stopped at 2 minutes, the most one dictation takes.") }
        phase = .transcribing(rowID: rowID)
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
            serial += 1
            let before = deliveries[rowID]?.text
            deliveries[rowID] = Delivery(serial: serial, text: before.map { $0 + " " + text } ?? text)
            if keyState != .saved { keyState = .saved }
        case .failure(.noKey):
            keyState = .missing
            needKey(rowID)
        case .failure(let failure):
            notice = Notice(rowID: rowID, text: failure.notice, settings: failure == .status(401))
        }
        idle()
    }

    private func idle() {
        phase = .idle
        onIdle?()
    }

    private func needKey(_ rowID: String) {
        notice = Notice(rowID: rowID, text: OpenAITranscription.Failure.noKey.notice, settings: true)
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
                if saved, self.notice?.settings == true { self.notice = nil }
            }
        }
    }
}
