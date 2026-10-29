import Foundation
import VibeCore

/// What sends a request: URLSession in the app, a stand-in in every test (no test reaches the network).
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// The app's: no cache, no cookies, so neither the audio nor the transcript is kept on disk by URLSession.
struct EphemeralHTTPClient: HTTPClient {
    let session = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
}

/// A recording to transcribe: its bytes and container, as recorded (the Mac's m4a, the phone's webm or mp4).
struct DictationAudio: Equatable, Sendable {
    var data: Data
    /// "audio/mp4", "audio/webm"…: the part's Content-Type.
    var mimeType: String
    /// Its length in seconds, as the recorder measured it.
    var duration: TimeInterval

    /// The file name OpenAI is given: it reads the container from the extension. Fixed per type, nothing of the user's.
    var fileName: String {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch base {
        case "audio/webm", "video/webm": return "audio.webm"
        case "audio/ogg": return "audio.ogg"
        case "audio/wav", "audio/x-wav", "audio/wave": return "audio.wav"
        case "audio/mpeg", "audio/mp3": return "audio.mp3"
        default: return "audio.m4a"
        }
    }
}

/// OpenAI's speech to text for dictation: `POST /v1/audio/transcriptions`, multipart, with three parts only (the
/// audio, the model, the vocabulary prompt), the key in the Authorization header only. The text comes back to the
/// composer for you to read before sending; nothing of it is logged.
struct OpenAITranscription: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// OpenAI's recommended transcription model (developers.openai.com/api/docs/guides/speech-to-text, 2026-10: the
    /// gpt-4o ones are deprecated, shut down 2027-02-26); Settings › General › Dictation changes it.
    static let defaultModel = "gpt-transcribe"
    /// The models Settings offers, best first.
    static let models = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    /// OpenAI's own limit on a file.
    static let maxBytes = 25 * 1024 * 1024
    static let timeout: TimeInterval = 60

    var client: HTTPClient = EphemeralHTTPClient()
    /// Fixed in tests, so a body can be compared byte for byte.
    var boundary: @Sendable () -> String = { "vs-\(UUID().uuidString)" }

    /// Why no text came: what the composer's one line says. Never the server's own message: OpenAI's 401 names part
    /// of the key it was given.
    enum Failure: Error, Equatable {
        case noKey
        case tooLong
        case status(Int)
        case network
        case empty
        case unreadable

        var notice: String {
            switch self {
            case .noKey: return "Dictation needs an OpenAI API key: add one in Settings › General › Dictation."
            case .tooLong: return "That recording is too long to transcribe: keep it under 2 minutes."
            case .status(401): return "OpenAI refused the API key (HTTP 401). Check it in Settings › General › Dictation."
            case .status(403): return "OpenAI refused this request (HTTP 403): the key's project may not allow audio."
            case .status(413): return "OpenAI found the recording too big (HTTP 413): keep it under 2 minutes."
            case .status(429): return "OpenAI says slow down or the account is out of credit (HTTP 429)."
            case .status(let code) where code >= 500: return "OpenAI had a problem (HTTP \(code)). Try again in a moment."
            case .status(let code): return "OpenAI couldn't transcribe it (HTTP \(code))."
            case .network: return "Couldn't reach OpenAI: check the network and try again."
            case .empty: return "Nothing was heard: hold the button while you speak."
            case .unreadable: return "OpenAI's answer couldn't be read."
            }
        }
    }

    /// The request for `audio` with `model` and the vocabulary `prompt` (left out when empty).
    func request(audio: DictationAudio, model: String, prompt: String, key: String) -> URLRequest {
        let boundary = boundary()
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.body(audio: audio, model: model, prompt: prompt, boundary: boundary)
        return request
    }

    /// The multipart body: `file`, `model` and, when there is one, `prompt`; nothing else.
    static func body(audio: DictationAudio, model: String, prompt: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(Self.partType(audio.mimeType))\r\n\r\n".utf8))
        body.append(audio.data)
        body.append(Data("\r\n".utf8))
        field("model", model)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// A Content-Type safe to put in a part's header: the type alone, no parameters, nothing that could end the line.
    static func partType(_ mimeType: String) -> String {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789/.+-")
        guard !base.isEmpty, base.unicodeScalars.allSatisfy(allowed.contains) else { return "application/octet-stream" }
        return base
    }

    /// The transcript of `audio`.
    func transcribe(_ audio: DictationAudio, model: String, prompt: String, key: String?) async throws -> String {
        guard let key, !key.isEmpty else { throw Failure.noKey }
        guard audio.data.count <= Self.maxBytes, audio.duration <= DictationLimits.maxDuration + 1 else { throw Failure.tooLong }
        guard !audio.data.isEmpty else { throw Failure.empty }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.send(request(audio: audio, model: model, prompt: prompt, key: key))
        } catch {
            throw Failure.network
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.status(http.statusCode) }
        return try Self.text(from: data)
    }

    /// The `text` of OpenAI's JSON answer, trimmed; an empty one is `.empty`.
    static func text(from data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let text = object["text"] as? String else {
            throw Failure.unreadable
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }
}
