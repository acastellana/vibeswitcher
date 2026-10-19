import Foundation
import VibeCore

/// ElevenLabs' text to speech, for the spoken briefing: `POST /v1/text-to-speech/<voice>` with the text, the model
/// and the language, the API key in the `xi-api-key` header only (never in the URL or the body), MP3 back. Called
/// only when you press Brief me, Play or Test voice (`BriefingModel`), and only when a key is saved.
struct ElevenLabs {
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/")!
    /// The current multilingual model (90+ languages, takes `language_code`; elevenlabs.io/docs/overview/models).
    static let model = "eleven_v4"
    /// "George", one of the premade voices every account has; `briefingVoice` in the defaults changes it.
    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"
    static let timeout: TimeInterval = 30

    var voice = UserDefaults.standard.string(forKey: "briefingVoice") ?? defaultVoice
    /// No cache, no cookies: a briefing's audio isn't kept on disk by URLSession.
    var session = URLSession(configuration: .ephemeral)

    /// Why no audio came: what the panel's one-line notice says.
    enum Failure: Error, Equatable {
        case status(Int)
        case network(String)
        case empty

        var notice: String {
            switch self {
            case .status(401), .status(403): return "ElevenLabs refused the key (HTTP \(code)), so the Mac's voice reads it."
            case .status: return "ElevenLabs answered HTTP \(code), so the Mac's voice reads it."
            case .network: return "ElevenLabs couldn't be reached, so the Mac's voice reads it."
            case .empty: return "ElevenLabs sent no audio, so the Mac's voice reads it."
            }
        }

        private var code: Int { if case .status(let code) = self { return code } else { return 0 } }
    }

    /// The request for `text` (redacted here, whoever wrote it) in `language`.
    func request(text: String, language: String, key: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(voice), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["text": Redaction.secrets(in: text), "model_id": Self.model, "language_code": language]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The speech for `text`, as MP3.
    func speech(text: String, language: String, key: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(text: text, language: language, key: key))
        } catch {
            throw Failure.network((error as NSError).localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.status(http.statusCode) }
        guard !data.isEmpty else { throw Failure.empty }
        return data
    }
}
