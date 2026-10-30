import AVFoundation
import Foundation

/// What records a dictation: the microphone in the app (`EngineRecorder`), a stand-in in every test (no test opens the
/// microphone). Called on the main thread.
protocol DictationRecorder: AnyObject {
    /// Whether the microphone may be used, asking macOS the first time; `done` on the main thread.
    func permission(_ done: @escaping (Bool) -> Void)
    /// Starts recording.
    func start() throws
    /// Stops: the recording, read into memory (its temporary file removed by then), or nil when nothing was recorded.
    func stop() -> DictationAudio?
    /// Stops and throws the recording away.
    func cancel()
}

/// The Mac's microphone through AVAudioEngine, converted to 16 kHz mono and encoded as AAC (about 4 KB a second)
/// into a file of its own in the user's private temporary folder, read back into memory and removed as soon as it
/// stops: no recording outlives `stop()`.
final class EngineRecorder: DictationRecorder {
    static let sampleRate: Double = 16_000
    static let bitRate = 32_000

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    /// The tap writes on the audio thread; `stop` waits for it here.
    private let lock = NSLock()
    private let folder: URL

    init(folder: URL = FileManager.default.temporaryDirectory) {
        self.folder = folder
    }

    enum Failure: Error {
        case noInput
        case encoder
    }

    func permission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
        default: done(false)
        }
    }

    func start() throws {
        cancel()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else { throw Failure.noInput }
        let url = folder.appendingPathComponent("vs-dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: Self.bitRate]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Failure.encoder
        }
        lock.withLock {
            self.file = file
            self.url = url
            self.frames = 0
        }
        let ratio = Self.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            self.lock.withLock {
                guard let file = self.file else { return }
                if (try? file.write(from: converted)) != nil { self.frames += AVAudioFramePosition(converted.frameLength) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cancel()
            throw Failure.noInput
        }
        self.engine = engine
    }

    func stop() -> DictationAudio? {
        let (url, frames) = finish()
        guard let url else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard frames > 0, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return DictationAudio(data: data, mimeType: "audio/mp4", duration: Double(frames) / Self.sampleRate)
    }

    func cancel() {
        if let url = finish().url { try? FileManager.default.removeItem(at: url) }
    }

    /// Stops the engine and closes the file: its URL (nil: none was recording) and the frames written.
    private func finish() -> (url: URL?, frames: AVAudioFramePosition) {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock {
            defer {
                file = nil      // closes it: the encoder writes the file's end
                url = nil
                frames = 0
            }
            return (url, frames)
        }
    }
}
