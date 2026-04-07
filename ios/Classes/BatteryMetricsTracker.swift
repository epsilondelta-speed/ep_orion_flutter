import Foundation
import UIKit

/// BatteryMetricsTracker — Full iOS implementation.
/// Mirrors BatteryMetricsTracker.kt exactly.
///
/// Thread-safety fixes:
///
/// 1. UIDevice.current.batteryLevel / batteryState MUST be read on the main
///    thread.  Previously getSessionMetrics() called currentBatteryLevel() /
///    isCharging() directly, but getSessionMetrics() is called from
///    FlutterSendData (platform thread, not main thread) → threading violation
///    that can crash on certain iOS versions.
///    Fix: cache the values on the main thread whenever they change, via
///    UIDevice battery notification observers.  All getters return the cached
///    values, which are safe to read from any thread.
///
/// 2. Double-call guard: both the Dart-side onAppForeground/Background methods
///    AND applicationDidBecomeActive / applicationDidEnterBackground call
///    onAppForegrounded / onAppBackgrounded.  This is by design — the Dart
///    lifecycle covers Flutter screens, the UIApplicationDelegate covers the
///    full app.  The NSLock ensures state is consistent either way.
final class BatteryMetricsTracker {

    // MARK: - Singleton
    static let shared = BatteryMetricsTracker()
    private init() {}

    // MARK: - Constants
    private let tag = "BatteryMetrics"
    private let sessionTimeoutMs: Double = 5 * 60 * 1000

    // MARK: - Cached battery values (written on main thread via notifications,
    //         read from any thread — safe because Int and Bool reads are atomic
    //         on all 64-bit Apple platforms; NSLock guards the compound state
    //         below separately).
    private var cachedBatteryLevel: Int  = -1
    private var cachedIsCharging:   Bool = false
    private var batteryObservers:   [NSObjectProtocol] = []

    // MARK: - Session state (guarded by lock)
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

        // ✅ Seed cache on main thread immediately.
        updateBatteryCache()

        // Observe battery changes so cache stays current.
        batteryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        batteryObservers.removeAll()

        let levelObs = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.updateBatteryCache() }

        let stateObs = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.updateBatteryCache() }

        batteryObservers = [levelObs, stateObs]
        OrionLogger.debug("\(tag): Initialized")
    }

    // MARK: - Cache update — MUST be called on main thread

    private func updateBatteryCache() {
        #if targetEnvironment(simulator)
        cachedBatteryLevel = 80
        cachedIsCharging   = false
        #else
        let level = UIDevice.current.batteryLevel
        cachedBatteryLevel = level < 0 ? -1 : Int(level * 100)
        let state = UIDevice.current.batteryState
        cachedIsCharging   = state == .charging || state == .full
        #endif
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

        isInForeground     = true
        lastForegroundTime = now
        OrionLogger.debug("\(tag): App foregrounded (battery: \(cachedBatteryLevel)%)")
    }

    func onAppBackgrounded() {
        lock.lock()
        defer { lock.unlock() }

        let now = nowMs()
        guard isInForeground else { return }

        let fgDuration      = now - lastForegroundTime
        totalForegroundTime += fgDuration
        isInForeground      = false
        lastBackgroundTime  = now
        OrionLogger.debug("\(tag): App backgrounded (fg: \(Int(fgDuration / 1000))s, battery: \(cachedBatteryLevel)%)")
    }

    // MARK: - Metrics

    func getSessionMetrics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        var currentFgTime = totalForegroundTime
        if isInForeground && lastForegroundTime > 0 {
            currentFgTime += nowMs() - lastForegroundTime
        }

        // ✅ Uses cached values — safe to read from any thread.
        let currentBattery = cachedBatteryLevel
        let batteryDrain   = sessionBatteryStart - currentBattery

        let totalDurationMs = nowMs() - sessionStartTime
        let totalDurMin     = totalDurationMs / 60_000.0
        let fgDurMin        = currentFgTime / 60_000.0
        let bgDurMin        = max(0.0, totalDurMin - fgDurMin)

        let drainPerFgHour = fgDurMin > 0
            ? (Double(batteryDrain) / fgDurMin) * 60.0
            : 0.0

        let drainPerTotalHour = totalDurMin > 0
            ? (Double(batteryDrain) / totalDurMin) * 60.0
            : 0.0

        let fgPct = totalDurMin > 0 ? (fgDurMin / totalDurMin) * 100.0 : 0.0

        return [
            "sessionBatteryStart":     sessionBatteryStart,
            "sessionBatteryCurrent":   currentBattery,
            "sessionBatteryDrain":     batteryDrain,
            "totalSessionDurationMin": String(format: "%.1f", totalDurMin),
            "foregroundDurationMin":   String(format: "%.1f", fgDurMin),
            "backgroundDurationMin":   String(format: "%.1f", bgDurMin),
            "drainPerForegroundHour":  String(format: "%.1f", drainPerFgHour),
            "drainPerTotalHour":       String(format: "%.1f", drainPerTotalHour),
            "foregroundPercentage":    String(format: "%.1f", fgPct),
            "sessionTimedOut":         sessionTimedOut,
            "isCharging":              cachedIsCharging,   // ✅ cached — safe off-main
            "isInForeground":          isInForeground
        ]
    }

    // MARK: - Private helpers (called inside lock)

    private func startNewSession() {
        sessionBatteryStart = cachedBatteryLevel  // ✅ cached
        sessionStartTime    = nowMs()
        totalForegroundTime = 0
        isSessionActive     = true
        sessionTimedOut     = false
        OrionLogger.debug("\(tag): New session started (battery: \(sessionBatteryStart)%)")
    }

    private func endSession() {
        OrionLogger.debug("\(tag): Session ended")
    }

    private func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000.0
    }

    func isSessionActiveStatus() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isSessionActive
    }

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
