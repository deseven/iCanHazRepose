import Foundation

/// Simple stdout logger for debug output.
/// All messages are prefixed with `[iCHR]` for easy identification.
enum Log {
    static func info(_ message: String) {
        print("[iCHR] \(message)")
    }
}
