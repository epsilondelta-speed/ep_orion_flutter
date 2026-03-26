import Foundation
import UIKit

/// BatteryMetricsTracker — Full iOS implementation.
/// Mirrors BatteryMetricsTracker.kt exactly.
final class BatteryMetricsTracker {

    // MARK: - Singleton
    static let shared = BatteryMetricsTracker()
    private init() {}

    // MARK: - Constants
    private let tag = "BatteryMetrics"
    private let sessionTimeoutMs: Double = 5 * 60 * 1000  // 5 minutes

    // MARK: - Session state
    private var sessionBatteryStart: Int    = -1
    private var sessionStartTime:    Double = 0
    private var isSessionActive:     Bool   = false
    private var totalForegroundTime: Double = 0
    private var lastForegroundTime:  Double = 0
    private var lastBackgroundTime:  Double = 0
    private var isInForeground:      Bool   = false
    private var sessionTimedOut:     Bool   = false
    private let lock = NSLock()

    // MARK: - Init

    func initialize() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        OrionLogger.debug("\(tag): Initialized")
    }

    // MARK: - Lifecycle

    func onAppForegrounded() {
        lock.lock()
        defer { lock.unlock() }

        let now = nowMs()

        if isSessionActive && lastBackgroundTime > 0 {
            let bgDuration = now - lastBackgroundTime
            if bgDuration > sessionTimeoutMs {
                OrionLogger.debug("\(tag): Session timed out (\(Int(bgDuration / 1000))s)")
                endSession()
                startNewSession()
                sessionTimedOut = true
            } else {
                OrionLogger.debug("\(tag): Session continues (bg: \(Int(bgDuration / 1000))s)")
                sessionTimedOut = false
            }
        } else {
            startNewSession()
        }

        isInForeground    = true
        lastForegroundTime = now
        OrionLogger.debug("\(tag): App foregrounded (battery: \(currentBatteryLevel())%)")
    }

    func onAppBackgrounded() {
        lock.lock()
        defer { lock.unlock() }

        let now = nowMs()
        if isInForeground {
            let fgDuration = now - lastForegroundTime
            totalForegroundTime += fgDuration
            isInForeground      = false
            lastBackgroundTime  = now
            OrionLogger.debug("\(tag): App backgrounded (fg: \(Int(fgDuration / 1000))s, battery: \(currentBatteryLevel())%)")
        }
    }

    // MARK: - Metrics (mirrors getSessionMetrics — same JSON keys as Android)

    func getSessionMetrics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        var currentFgTime = totalForegroundTime
        if isInForeground && lastForegroundTime > 0 {
            currentFgTime += nowMs() - lastForegroundTime
        }

        let currentBattery = currentBatteryLevel()
        let batteryDrain   = sessionBatteryStart - currentBattery

        let totalDurationMs = nowMs() - sessionStartTime
        let totalDurMin     = totalDurationMs / 60_000.0
        let fgDurMin        = currentFgTime / 60_000.0
        // ✅ Fix: max(0, ...) prevents -0.0 when fg == total
        let bgDurMin        = max(0.0, totalDurMin - fgDurMin)

        let drainPerFgHour = fgDurMin > 0
            ? (Double(batteryDrain) / fgDurMin) * 60.0
            : 0.0

        let drainPerTotalHour = totalDurMin > 0
            ? (Double(batteryDrain) / totalDurMin) * 60.0
            : 0.0

        let fgPct = totalDurMin > 0
            ? (fgDurMin / totalDurMin) * 100.0
            : 0.0

        return [
            "sessionBatteryStart":   sessionBatteryStart,
            "sessionBatteryCurrent": currentBattery,
            "sessionBatteryDrain":   batteryDrain,
            "totalSessionDurationMin": String(format: "%.1f", totalDurMin),
            "foregroundDurationMin":   String(format: "%.1f", fgDurMin),
            "backgroundDurationMin":   String(format: "%.1f", bgDurMin),
            "drainPerForegroundHour":  String(format: "%.1f", drainPerFgHour),
            "drainPerTotalHour":       String(format: "%.1f", drainPerTotalHour),
            "foregroundPercentage":    String(format: "%.1f", fgPct),
            "sessionTimedOut":         sessionTimedOut,
            "isCharging":              isCharging(),
            "isInForeground":          isInForeground
        ]
    }

    // MARK: - Private

    private func startNewSession() {
        sessionBatteryStart = currentBatteryLevel()
        sessionStartTime    = nowMs()
        totalForegroundTime = 0
        isSessionActive     = true
        sessionTimedOut     = false
        OrionLogger.debug("\(tag): New session started (battery: \(sessionBatteryStart)%)")
    }

    private func endSession() {
        OrionLogger.debug("\(tag): Session ended")
    }

    private func currentBatteryLevel() -> Int {
        #if targetEnvironment(simulator)
        return 80
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? -1 : Int(level * 100)
        #endif
    }

    private func isCharging() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #endif
    }

    private func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000.0
    }

    func isSessionActiveStatus() -> Bool { return isSessionActive }

    func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        sessionBatteryStart = -1
        sessionStartTime    = 0
        totalForegroundTime = 0
        lastForegroundTime  = 0
        lastBackgroundTime  = 0
        isInForeground      = false
        isSessionActive     = false
        sessionTimedOut     = false
        OrionLogger.debug("\(tag): Session reset")
    }
}
