import Foundation

/// Centralized logging utility for Orion SDK.
/// Mirrors OrionLogger.kt — logs only in DEBUG builds, tagged "Orion".
final class OrionLogger {

    static let tag = "Orion"

    /// Enable/disable logging. Defaults to true in DEBUG, false in RELEASE.
    static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    static func debug(_ message: String) {
        guard isEnabled else { return }
        print("[\(tag)] D: \(message)")
    }

    static func warn(_ message: String) {
        guard isEnabled else { return }
        print("[\(tag)] W: \(message)")
    }

    static func error(_ message: String) {
        guard isEnabled else { return }
        print("[\(tag)] E: \(message)")
    }

    static func error(_ message: String, _ error: Error?) {
        guard isEnabled else { return }
        if let error = error {
            print("[\(tag)] E: \(message) — \(error.localizedDescription)")
        } else {
            print("[\(tag)] E: \(message)")
        }
    }

    static func info(_ message: String) {
        guard isEnabled else { return }
        print("[\(tag)] I: \(message)")
    }

    static func verbose(_ message: String) {
        guard isEnabled else { return }
        print("[\(tag)] V: \(message)")
    }
}
