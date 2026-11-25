// The node's LocalAuthentication call (Platform.Approval, compiled from Sources/VibePlatform unchanged), alone, for the
// design's step 4 measurements. Built by scripts/mac-measure/lib.sh.
//
//   la can                    what canEvaluatePolicy says (shows nothing): availability(), biometry, both policies
//   la ask REASON [TIMEOUT]   puts the system's dialog on screen with REASON and prints how it ended. Refused unless
//                             MEASURE_ASK=yes is set: only the user's scripts set it, after saying what will appear
import Foundation
import LocalAuthentication

func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

func can() {
    print("availability=\(Platform.Approval.availability() ?? "available")")
    let context = LAContext()
    var error: NSError?
    let owner = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    print("deviceOwnerAuthentication=\(owner) error=\(error.map { "\($0.code) \($0.localizedDescription)" } ?? "none")")
    error = nil
    let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    print("deviceOwnerAuthenticationWithBiometrics=\(biometrics) error=\(error.map { "\($0.code) \($0.localizedDescription)" } ?? "none")")
    let kind: String
    switch context.biometryType {
    case .none: kind = "none"
    case .touchID: kind = "touchID"
    case .faceID: kind = "faceID"
    case .opticID: kind = "opticID"
    @unknown default: kind = "unknown(\(context.biometryType.rawValue))"
    }
    print("biometryType=\(kind)")
}

@main
enum LA {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        print("la: pid=\(getpid()) ppid=\(getppid()) at=\(stamp())")
        switch arguments.first {
        case "can":
            can()
        case "ask":
            guard ProcessInfo.processInfo.environment["MEASURE_ASK"] == "yes" else {
                FileHandle.standardError.write(Data("la: ask refused: MEASURE_ASK=yes isn't set (only the user's measurement scripts set it)\n".utf8))
                exit(65)
            }
            guard arguments.count >= 2, !arguments[1].isEmpty else {
                FileHandle.standardError.write(Data("usage: la ask REASON [TIMEOUT]\n".utf8))
                exit(64)
            }
            let timeout = arguments.count >= 3 ? TimeInterval(arguments[2]) ?? 60 : 60
            can()
            print("asking at=\(stamp()) timeout=\(Int(timeout))s reason=\(arguments[1])")
            let started = Date()
            let outcome = Platform.Approval.ask(arguments[1], timeout: timeout)
            print("outcome=\(outcome) after=\(String(format: "%.1f", Date().timeIntervalSince(started)))s at=\(stamp())")
        default:
            FileHandle.standardError.write(Data("usage: la can | la ask REASON [TIMEOUT]\n".utf8))
            exit(64)
        }
    }
}
