import Foundation

/// Whether a session's program asked for focus events (DECSET 1004: the terminal tells it `CSI I` when it gains focus,
/// `CSI O` when it loses it), read off its output as it goes by: `CSI ? … 1004 … h` turns them on, `… l` off, and a
/// full reset (`ESC c`) off, as SwiftTerm's own terminal takes them. A sequence split across reads is still read.
/// Only a program that asked parses `CSI I`: to any other it's Esc and two typed characters.
struct FocusEvents {
    private(set) var on = false

    private enum State { case ground, escape, csi, privateMode, ignored }
    private var state = State.ground
    private var parameters: [UInt8] = []

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes { step(byte) }
    }

    private mutating func step(_ byte: UInt8) {
        let escape: UInt8 = 0x1b
        let final = 0x40...0x7e as ClosedRange<UInt8>
        switch state {
        case .ground:
            if byte == escape { state = .escape }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "c"): on = false; state = .ground
            case escape: state = .escape
            default: state = .ground
            }
        case .csi:
            if byte == UInt8(ascii: "?") {
                parameters = []
                state = .privateMode
            } else if byte == escape {
                state = .escape
            } else if final.contains(byte) {
                state = .ground
            }
        case .privateMode:
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ";") {
                // A run of parameters longer than any real one isn't a mode setting.
                if parameters.count < 64 { parameters.append(byte) } else { state = .ignored }
            } else if byte == UInt8(ascii: "h") || byte == UInt8(ascii: "l") {
                if parameters.split(separator: UInt8(ascii: ";")).contains(where: { Array($0) == Array("1004".utf8) }) {
                    on = byte == UInt8(ascii: "h")
                }
                state = .ground
            } else if byte == escape {
                state = .escape
            } else if final.contains(byte) {
                state = .ground
            } else {
                // An intermediate (`$` in a mode query): not a setting.
                state = .ignored
            }
        case .ignored:
            if byte == escape { state = .escape } else if final.contains(byte) { state = .ground }
        }
    }
}
