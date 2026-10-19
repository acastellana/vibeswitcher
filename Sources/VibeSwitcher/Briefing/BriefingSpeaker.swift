import AVFoundation
import Foundation

/// What reads a briefing aloud: ElevenLabs' audio, or the Mac's own voice. Faked in tests (no sound there).
protocol BriefingVoice: AnyObject {
    /// Plays MP3 audio; false when it can't be played.
    func play(_ audio: Data) -> Bool
    /// Says `text` with the Mac's voice for `language` (an ElevenLabs language code).
    func say(_ text: String, language: String)
    func stop()
    /// Called once what's playing ends by itself.
    var finished: () -> Void { get set }
}

/// The real one: AVAudioPlayer for ElevenLabs' MP3, AVSpeechSynthesizer for the Mac's voice.
final class BriefingSpeaker: NSObject, BriefingVoice {
    var finished: () -> Void = {}
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(_ audio: Data) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(data: audio) else { return false }
        player.delegate = self
        self.player = player
        return player.play()
    }

    func say(_ text: String, language: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        // The Mac's voice for the language, when it has one (else the system's).
        utterance.voice = AVSpeechSynthesisVoice(language: Self.locale(language)) ?? AVSpeechSynthesisVoice(language: language)
        synthesizer.speak(utterance)
    }

    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// A language code as the Mac's voices are named ("es" → "es-ES"): the user's region when it fits, else the
    /// language's first voice.
    static func locale(_ language: String) -> String {
        let region = Locale.current.region?.identifier ?? ""
        let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        if voices.contains("\(language)-\(region)") { return "\(language)-\(region)" }
        return voices.first { $0.hasPrefix(language + "-") } ?? language
    }
}

extension BriefingSpeaker: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.player === player else { return }
            self.player = nil
            self.finished()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }
}
