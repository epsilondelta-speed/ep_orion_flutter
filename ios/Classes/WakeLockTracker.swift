import Foundation
import UIKit

/// WakeLockTracker — Full iOS implementation.
/// Mirrors WakeLockTracker.kt exactly.
final class WakeLockTracker {

    // MARK: - Singleton
    static let shared = WakeLockTracker()
    private init() {}

    // MARK: - Config
    var stuckThresholdMs: Int = 60_000

    // MARK: - Types
    static let typePartial:            Int = 1
    static let typeProximityScreenOff: Int = 32

    // MARK: - Active wake lock info
    private struct ActiveWakeLockInfo {
        let tag:             String
        let type:            Int
        let acquireTimeMs:   Double
        let timeoutMs:       Int?
        let wasInForeground: Bool
        var bgStartTimeMs:   Double?
        var bgTaskId:        UIBackgroundTaskIdentifier = .invalid
    }

    // MARK: - Per-tag session metrics
    private struct WakeLockSessionMetrics {
        let tag:          String
        var type:         Int    = 1
        var acquireCount: Int    = 0
        var totalHeldMs:  Double = 0
        var maxHeldMs:    Double = 0
        var backgroundMs: Double = 0
        var stuckCount:   Int    = 0
    }

    // MARK: - State
    private var activeWakeLocks   = [String: ActiveWakeLockInfo]()
    private var sessionMetricsMap = [String: WakeLockSessionMetrics]()
    private var totalAcquireCount = 0
    private var totalHeldTimeMs:  Double = 0
    private var totalBgTimeMs:    Double = 0
    private var maxSingleHeldMs:  Double = 0
    private var stuckCount        = 0
    private var isAppInForeground = true
    private let lock              = NSLock()

    // MARK: - Init

    func initialize() {
        OrionLogger.debug("WakeLockTracker: Initialized")
    }

    // MARK: - App Lifecycle

    func onAppForeground() {
        lock.lock()
        defer { lock.unlock() }
        let now = nowMs()
        for (tag, var info) in activeWakeLocks {
            if let bgStart = info.bgStartTimeMs {
                let bgDuration = now - bgStart
                if var metrics = sessionMetricsMap[tag] {
                    metrics.backgroundMs += bgDuration
                    sessionMetricsMap[tag] = metrics
                }
                totalBgTimeMs += bgDuration
                info.bgStartTimeMs = nil
                activeWakeLocks[tag] = info
            }
        }
        isAppInForeground = true
        OrionLogger.debug("WakeLockTracker: App foregrounded")
    }

    func onAppBackground() {
        lock.lock()
        defer { lock.unlock() }
        let now = nowMs()
        for (tag, var info) in activeWakeLocks {
            if info.bgStartTimeMs == nil {
                info.bgStartTimeMs = now
                activeWakeLocks[tag] = info
            }
        }
        isAppInForeground = false
        OrionLogger.debug("WakeLockTracker: App backgrounded")
    }

    // MARK: - Acquire

    @discardableResult
    func acquire(tag: String, timeoutMs: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeWakeLocks[tag] == nil else {
            OrionLogger.debug("WakeLockTracker: '\(tag)' already held")
            return true
        }

        // Use a class-based box so the expiry closure can reference
        // the task ID without Swift's "mutated after capture" error
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: tag) {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = UIBackgroundTaskIdentifier.invalid
        }

        let now = nowMs()
        var info = ActiveWakeLockInfo(
            tag:             tag,
            type:            WakeLockTracker.typePartial,
            acquireTimeMs:   now,
            timeoutMs:       timeoutMs,
            wasInForeground: isAppInForeground,
            bgStartTimeMs:   isAppInForeground ? nil : now
        )
        info.bgTaskId = box.id
        activeWakeLocks[tag] = info

        if sessionMetricsMap[tag] == nil {
            sessionMetricsMap[tag] = WakeLockSessionMetrics(tag: tag)
        }
        if var metrics = sessionMetricsMap[tag] {
            metrics.acquireCount += 1
            sessionMetricsMap[tag] = metrics
        }
        totalAcquireCount += 1

        if let timeout = timeoutMs {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeout)) {
                [weak self] in self?.release(tag: tag)
            }
        }

        OrionLogger.debug("WakeLockTracker: locked '\(tag)'")
        return box.id != UIBackgroundTaskIdentifier.invalid
    }

    // MARK: - Release

    func release(tag: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let info = activeWakeLocks.removeValue(forKey: tag) else {
            OrionLogger.debug("WakeLockTracker: release called for unknown '\(tag)'")
            return
        }

        if info.bgTaskId != UIBackgroundTaskIdentifier.invalid {
            UIApplication.shared.endBackgroundTask(info.bgTaskId)
        }

        let now          = nowMs()
        let heldMs       = now - info.acquireTimeMs
        var bgMs: Double = 0
        if let bgStart   = info.bgStartTimeMs { bgMs = now - bgStart }
        let isStuck      = heldMs >= Double(stuckThresholdMs)

        if var metrics = sessionMetricsMap[tag] {
            metrics.totalHeldMs  += heldMs
            metrics.maxHeldMs     = max(metrics.maxHeldMs, heldMs)
            metrics.backgroundMs += bgMs
            if isStuck { metrics.stuckCount += 1 }
            sessionMetricsMap[tag] = metrics
        }

        totalHeldTimeMs += heldMs
        totalBgTimeMs   += bgMs
        maxSingleHeldMs  = max(maxSingleHeldMs, heldMs)
        if isStuck { stuckCount += 1 }

        OrionLogger.debug("WakeLockTracker: released '\(tag)' after \(Int(heldMs))ms\(isStuck ? " STUCK" : "")")
    }

    // MARK: - Manual Tracking

    func trackAcquire(tag: String, timeoutMs: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard activeWakeLocks[tag] == nil else { return }

        let now = nowMs()
        let info = ActiveWakeLockInfo(
            tag:             tag,
            type:            WakeLockTracker.typePartial,
            acquireTimeMs:   now,
            timeoutMs:       timeoutMs,
            wasInForeground: isAppInForeground,
            bgStartTimeMs:   isAppInForeground ? nil : now
        )
        activeWakeLocks[tag] = info

        if sessionMetricsMap[tag] == nil {
            sessionMetricsMap[tag] = WakeLockSessionMetrics(tag: tag)
        }
        if var metrics = sessionMetricsMap[tag] {
            metrics.acquireCount += 1
            sessionMetricsMap[tag] = metrics
        }
        totalAcquireCount += 1
        OrionLogger.debug("WakeLockTracker: manual acquire '\(tag)'")
    }

    func trackRelease(tag: String) { release(tag: tag) }

    // MARK: - Query

    func getActiveCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return activeWakeLocks.count
    }

    func isHeld(tag: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeWakeLocks[tag] != nil
    }

    func getActiveTags() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(activeWakeLocks.keys)
    }

    // MARK: - Session Metrics

    func getSessionMetrics(maxLocks: Int = 10) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let now = nowMs()
        var additionalHeld: Double = 0
        var additionalBg:   Double = 0
        var currentlyActive = 0

        for info in activeWakeLocks.values {
            additionalHeld  += now - info.acquireTimeMs
            currentlyActive += 1
            if let bgStart = info.bgStartTimeMs { additionalBg += now - bgStart }
        }

        var result: [String: Any] = [
            "totalMs":       Int(totalHeldTimeMs + additionalHeld),
            "count":         totalAcquireCount,
            "bgMs":          Int(totalBgTimeMs + additionalBg),
            "maxMs":         Int(maxSingleHeldMs),
            "stuckCnt":      stuckCount,
            "stuckThreshMs": stuckThresholdMs,
            "activeCnt":     currentlyActive
        ]

        let sorted = sessionMetricsMap.values
            .sorted { $0.totalHeldMs > $1.totalHeldMs }
            .prefix(maxLocks)

        if !sorted.isEmpty {
            var locksArray = [[String: Any]]()
            for metrics in sorted {
                var extraHeld: Double = 0
                var extraBg:   Double = 0
                let isActive = activeWakeLocks[metrics.tag] != nil
                if let activeInfo = activeWakeLocks[metrics.tag] {
                    extraHeld = now - activeInfo.acquireTimeMs
                    if let bgStart = activeInfo.bgStartTimeMs { extraBg = now - bgStart }
                }
                var lockDict: [String: Any] = [
                    "tag":     metrics.tag,
                    "cnt":     metrics.acquireCount,
                    "totalMs": Int(metrics.totalHeldMs + extraHeld),
                    "maxMs":   Int(metrics.maxHeldMs),
                    "bgMs":    Int(metrics.backgroundMs + extraBg)
                ]
                if metrics.stuckCount > 0 { lockDict["stuck"] = metrics.stuckCount }
                if isActive              { lockDict["active"] = true }
                locksArray.append(lockDict)
            }
            result["locks"] = locksArray
        }
        return result
    }

    func logState() {
        OrionLogger.debug("WakeLockTracker: \(getSessionMetrics())")
    }

    private func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000.0
    }
}

// MARK: - TaskBox
// Class wrapper so the background task expiry closure can mutate
// the task ID safely — avoids Swift "mutated after capture" compile error
private final class TaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
}
