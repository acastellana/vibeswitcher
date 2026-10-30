import AppKit
import AVFoundation

/// Whether VibeSwitcher may use the microphone, as macOS says. It's asked about VibeSwitcher for both kinds of
/// dictation: the app records for OpenAI itself, and a session's Claude Code records under it (the session host, its
/// launcher and claude are spawned from the app without disclaiming it, so VibeSwitcher is their responsible process).
enum MicrophoneStatus: Equatable, Sendable {
    case allowed
    /// Never asked: the first press asks.
    case undetermined
    /// Denied, or restricted by a profile.
    case denied
}

/// What dictation asks before it records (tests give their own: never the Mac's).
protocol MicrophoneAuthorizer: AnyObject {
    var status: MicrophoneStatus { get }
    /// Asks macOS (its dialog, once); `done` on the main thread.
    func request(_ done: @escaping (Bool) -> Void)
}

/// The Mac's: AVCaptureDevice's authorization for audio.
final class SystemMicrophone: MicrophoneAuthorizer {
    var status: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .undetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func request(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
    }

    /// System Settings › Privacy & Security › Microphone.
    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    static func openSettings() {
        NSWorkspace.shared.open(settings)
    }
}
