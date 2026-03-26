import Foundation

/// SessionManager — Manages user session IDs with 30-minute timeout renewal.
/// Mirrors SessionManager.kt exactly.
final class SessionManager {

    private static let prefsSessionId   = "orion_session_id"
    private static let prefsLastUpdated = "orion_session_last_updated"
    private static let sessionTimeoutMs: Double = 30 * 60 * 1000

    private static var isInitialized = false
    private static let lock = NSLock()

    static func initialize() {
        lock.lock()
        defer { lock.unlock() }
        guard !isInitialized else { return }
        isInitialized = true
        OrionLogger.debug("SessionManager: Initialized")
    }

    static func getSessionId() -> String {
        lock.lock()
        defer { lock.unlock() }

        let defaults    = UserDefaults.standard
        let now         = currentTimeMs()
        let lastUpdated = defaults.double(forKey: prefsLastUpdated)
        let sessionId   = defaults.string(forKey: prefsSessionId)

        if sessionId == nil || (now - lastUpdated) > sessionTimeoutMs {
            // ✅ lowercased() to match Android UUID format
            let newId = UUID().uuidString.lowercased()
            saveSessionId(newId)
            OrionLogger.debug("SessionManager: New session: \(String(newId.prefix(8)))...")
            return newId
        }
        return sessionId!
    }

    static func updateSessionTimestamp() {
        UserDefaults.standard.set(currentTimeMs(), forKey: prefsLastUpdated)
    }

    @discardableResult
    static func forceNewSession() -> String {
        lock.lock()
        defer { lock.unlock() }
        // ✅ lowercased() to match Android UUID format
        let newId = UUID().uuidString.lowercased()
        saveSessionId(newId)
        OrionLogger.debug("SessionManager: Forced new session: \(String(newId.prefix(8)))...")
        return newId
    }

    static func getSessionRemainingTimeMs() -> Double {
        let lastUpdated = UserDefaults.standard.double(forKey: prefsLastUpdated)
        let remaining   = sessionTimeoutMs - (currentTimeMs() - lastUpdated)
        return max(remaining, 0)
    }

    static func isReady() -> Bool { return isInitialized }

    private static func saveSessionId(_ id: String) {
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: prefsSessionId)
        defaults.set(currentTimeMs(), forKey: prefsLastUpdated)
    }

    static func currentTimeMs() -> Double {
        return Date().timeIntervalSince1970 * 1000
    }
}
