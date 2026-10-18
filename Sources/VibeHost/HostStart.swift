import Darwin
import Foundation
import VibeCore

/// What the app hands the host it starts.
public enum HostStart {
    /// The app's key (see `AppProof`), when stdin is a pipe that carries exactly one: the app writes it and closes
    /// its end before the host reads. Stdin is /dev/null afterwards. Nil for anything else (a host run by hand, or
    /// by an app from before keys).
    public static func appKeyFromStdin(waiting: TimeInterval = 2) -> Data? {
        var info = stat()
        guard fstat(0, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return nil }
        defer {
            let null = open("/dev/null", O_RDONLY)
            if null >= 0, null != 0 { dup2(null, 0); close(null) }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(waiting)
        while data.count <= AppProof.keySize {
            var ready = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32(max(0, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            let count = read(0, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count == AppProof.keySize ? data : nil
    }
}
