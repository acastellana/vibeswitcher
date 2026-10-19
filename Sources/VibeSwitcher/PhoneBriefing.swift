import AVFoundation
import Foundation
import VibeCore

/// A briefing for the phone (`/api/briefing` in `PhoneAccess`): its text, and its audio made on the Mac for the phone
/// to play. The ElevenLabs key is never part of it.
struct PhoneBriefing: Equatable, Sendable {
    var text: String
    /// ElevenLabs' language code (the template's is "en").
    var language: String
    var at: Double
    /// One line when it isn't what was asked for: the English template, the Mac's voice in place of ElevenLabs'.
    var notice: String?
    /// "elevenlabs" or "mac"; nil when no audio could be made (the phone shows the text alone).
    var voice: String?
    var audio: Data?
    var audioType: String?

    /// What the phone gets: the text redacted again on the way out, the audio as base64.
    var json: [String: Any] {
        var object: [String: Any] = ["text": Redaction.secrets(in: text), "language": language, "at": at]
        if let notice { object["notice"] = notice }
        if let voice, let audio, let audioType {
            object["voice"] = voice
            object["audio"] = audio.base64EncodedString()
            object["audioType"] = audioType
        }
        return object
    }
}

/// Brief me from the phone: the same briefing as the Mac's button (`Briefing.compose` and `write`, headless Claude in
/// the chosen language), read aloud on the phone instead of the Mac. With an ElevenLabs key its MP3 is sent; without
/// one, or when ElevenLabs fails, the Mac's own voice is rendered to an AAC file (`MacVoiceFile`) and that is sent. The
/// key is read here, off the main thread, and goes to ElevenLabs only. A phone's briefing counts as the last briefing
/// for the Mac's button too (the next one, on either, covers what's new since).
final class PhoneBriefer: @unchecked Sendable {
    private let snapshot: () -> BriefingModel.Snapshot
    private let language: () -> BriefingLanguage
    private let keyStore: SecretStore
    private let generate: @Sendable (String) -> String?
    private let client: ElevenLabs
    private let render: @Sendable (String, String) -> Data?
    private let defaults: UserDefaults
    private let now: () -> Double

    init(snapshot: @escaping () -> BriefingModel.Snapshot, language: @escaping () -> BriefingLanguage, keyStore: SecretStore,
         generate: @escaping @Sendable (String) -> String? = { ClaudeHeadless.brief($0) }, client: ElevenLabs = ElevenLabs(),
         render: @escaping @Sendable (String, String) -> Data? = { MacVoiceFile.render($0, language: $1) },
         defaults: UserDefaults = .standard, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.snapshot = snapshot
        self.language = language
        self.keyStore = keyStore
        self.generate = generate
        self.client = client
        self.render = render
        self.defaults = defaults
        self.now = now
    }

    /// Writes one and makes its audio; called on the main thread, and `done` is called there.
    func brief(_ done: @escaping (PhoneBriefing) -> Void) {
        let taken = snapshot()
        let language = language()
        let since = defaults.object(forKey: BriefingModel.lastKey) as? Double
        let at = now()
        let (generate, keyStore, client, render) = (generate, keyStore, client, render)
        DispatchQueue.global(qos: .userInitiated).async {
            let input = Briefing.compose(BriefingModel.sources(taken.boards), sessions: taken.sessions, lastBriefed: since, now: at)
            let written = Briefing.write(input, language: language, generate: generate, now: at)
            let key = keyStore.read()
            Task.detached(priority: .userInitiated) {
                let briefing = await Self.voiced(written, key: key, client: client, render: render)
                DispatchQueue.main.async {
                    self.defaults.set(written.at, forKey: BriefingModel.lastKey)
                    done(briefing)
                }
            }
        }
    }

    /// `written` with its audio: ElevenLabs' when there's a key and it answers, else the Mac's voice.
    static func voiced(_ written: BriefingText, key: String?, client: ElevenLabs,
                       render: @Sendable (String, String) -> Data?) async -> PhoneBriefing {
        let code = written.language.code
        var briefing = PhoneBriefing(text: written.text, language: code, at: written.at, notice: written.notice)
        var notices = [written.notice].compactMap { $0 }
        if let key, !key.isEmpty {
            do {
                briefing.audio = try await client.speech(text: written.text, language: code, key: key)
                briefing.voice = "elevenlabs"
                briefing.audioType = "audio/mpeg"
                return briefing
            } catch {
                notices.append((error as? ElevenLabs.Failure ?? .empty).notice)
            }
        }
        if let audio = render(written.text, code), !audio.isEmpty {
            briefing.audio = audio
            briefing.voice = "mac"
            briefing.audioType = "audio/mp4"
        } else {
            notices.append("No audio could be made on the Mac, so here's the text.")
        }
        briefing.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
        return briefing
    }
}

/// The Mac's own voice for a text, rendered to an AAC (.m4a) file instead of the speakers: what the phone plays when
/// there's no ElevenLabs key. The same voice `BriefingSpeaker` would use; the file is a temporary one, removed once read.
enum MacVoiceFile {
    /// The audio, or nil when the Mac has no voice for it or it takes longer than `timeout`. Blocks; not on main. The
    /// file is written in `folder` (a test's scratch folder; the user's temporary folder otherwise).
    static func render(_ text: String, language: String, timeout: TimeInterval = 60,
                       folder: URL = FileManager.default.temporaryDirectory) -> Data? {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: BriefingSpeaker.locale(language)) ?? AVSpeechSynthesisVoice(language: language)
        let url = folder.appendingPathComponent("vs-briefing-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = NSLock()
        var file: AVAudioFile?
        var failed = false
        let finished = DispatchSemaphore(value: 0)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !failed else { return }
            // An empty buffer is the end.
            guard pcm.frameLength > 0 else {
                finished.signal()
                return
            }
            do {
                if file == nil {
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: pcm.format.sampleRate,
                                                   AVNumberOfChannelsKey: pcm.format.channelCount]
                    file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: pcm.format.commonFormat,
                                           interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            } catch {
                failed = true
                finished.signal()
            }
        }
        let done = finished.wait(timeout: .now() + timeout) == .success
        if !done { synthesizer.stopSpeaking(at: .immediate) }
        lock.lock()
        let written = done && !failed && file != nil
        failed = true      // a late buffer writes nothing
        file = nil         // closes it
        lock.unlock()
        guard written, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }
}
