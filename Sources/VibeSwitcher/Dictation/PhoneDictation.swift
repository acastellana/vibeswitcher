import Foundation
import VibeCore

/// Dictation from the phone (`POST /api/dictation` in `PhoneAccess`): the phone's recording is transcribed here, with
/// the Mac's OpenAI key (read off the main thread, sent to OpenAI only) and the session's vocabulary. The phone gets
/// the text back, never the key; the recording isn't kept.
final class PhoneDictation: @unchecked Sendable {
    private let keyStore: SecretStore
    private let transcription: OpenAITranscription
    private let model: () -> String
    /// The session with that identity, looked up on the main thread.
    private let session: (String) -> Session?
    private let vocabulary: @Sendable (Session) -> String

    init(keyStore: SecretStore, transcription: OpenAITranscription = OpenAITranscription(), model: @escaping () -> String,
         session: @escaping (String) -> Session?,
         vocabulary: @escaping @Sendable (Session) -> String = { DictationVocabulary.prompt(for: $0) }) {
        self.keyStore = keyStore
        self.transcription = transcription
        self.model = model
        self.session = session
        self.vocabulary = vocabulary
    }

    /// Called on the main thread; `done` is called there.
    func transcribe(_ audio: DictationAudio, sid: String?, _ done: @escaping (Result<String, OpenAITranscription.Failure>) -> Void) {
        let target = sid.flatMap(session)
        let (keyStore, transcription, model, vocabulary) = (keyStore, transcription, model(), vocabulary)
        DispatchQueue.global(qos: .userInitiated).async {
            let key = keyStore.read()
            let prompt = target.map(vocabulary) ?? ""
            Task.detached(priority: .userInitiated) {
                let result: Result<String, OpenAITranscription.Failure>
                do {
                    result = .success(try await transcription.transcribe(audio, model: model, prompt: prompt, key: key))
                } catch {
                    result = .failure(error as? OpenAITranscription.Failure ?? .unreadable)
                }
                DispatchQueue.main.async { done(result) }
            }
        }
    }
}
