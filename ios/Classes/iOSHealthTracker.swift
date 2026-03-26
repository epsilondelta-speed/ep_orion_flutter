import Foundation
import UIKit

/// iOSHealthTracker — Tracks iOS-specific device health signals.
///
/// Captures metrics that have no Android equivalent:
/// - Thermal state (nominal/fair/serious/critical)
/// - Low power mode status
/// - Memory pressure warning count per session
/// - Main thread hang count per session (>500ms)
///
/// These are added to every beacon under "iosHealth" key.
/// Android beacons simply won't have this key — server handles gracefully.
final class iOSHealthTracker {

    // MARK: - Singleton
    static let shared = iOSHealthTracker()
    private init() {}

    // MARK: - State
    private var memoryWarningCount: Int = 0
    private var hangCount:          Int = 0
    private var sessionStartTime:   Date = Date()
    private var observers:          [NSObjectProtocol] = []
    private let lock =              NSLock()

    // MARK: - Init

    func initialize() {
        sessionStartTime    = Date()
        memoryWarningCount  = 0
        hangCount           = 0

        // Remove old observers if re-initializing
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        // Memory warning observer — mirrors onTrimMemory in Android
        let memObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            self?.lock.lock()
            self?.memoryWarningCount += 1
            self?.lock.unlock()
            OrionLogger.debug("iOSHealthTracker: ⚠️ Memory warning #\(self?.memoryWarningCount ?? 0)")
        }
        observers.append(memObs)

        // Low power mode observer
        let lpObs = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object:  nil,
            queue:   .main
        ) { _ in
            let isLow = ProcessInfo.processInfo.isLowPowerModeEnabled
            OrionLogger.debug("iOSHealthTracker: Low power mode → \(isLow)")
        }
        observers.append(lpObs)

        // Thermal state observer
        let thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object:  nil,
            queue:   .main
        ) { _ in
            let state = ProcessInfo.processInfo.thermalState
            OrionLogger.debug("iOSHealthTracker: Thermal state → \(state.rawValue)")
        }
        observers.append(thermalObs)

        startHangDetection()
        OrionLogger.debug("iOSHealthTracker: Initialized")
    }

    // MARK: - Hang Detection
    // Detects main thread hangs > 500ms by pinging from background thread
    // Mirrors Android ANR detection concept

    private var hangDetectorTimer: DispatchSourceTimer?
    private var lastMainThreadPing: Date = Date()

    private func startHangDetection() {
        // Ping main thread every 250ms from background
        // If main thread doesn't respond within 500ms — it's a hang
        let pingInterval: TimeInterval = 0.25
        let hangThreshold: TimeInterval = 0.5

        hangDetectorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.lastMainThreadPing)

            if gap > hangThreshold {
                self.lock.lock()
                self.hangCount += 1
                self.lock.unlock()
                OrionLogger.debug("iOSHealthTracker: ⚠️ Main thread hang detected (\(Int(gap * 1000))ms)")
            }

            // Ping main thread
            DispatchQueue.main.async { [weak self] in
                self?.lastMainThreadPing = Date()
            }
        }
        timer.resume()
        hangDetectorTimer = timer
    }

    // MARK: - Thermal State

    /// Returns current thermal state as string — matches iOS naming
    /// nominal → fair → serious → critical
    func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Returns thermal state as integer for easy server-side comparison
    /// 0=nominal, 1=fair, 2=serious, 3=critical (mirrors severity scale)
    func thermalStateLevel() -> Int {
        return Int(ProcessInfo.processInfo.thermalState.rawValue)
    }

    // MARK: - Session Metrics

    /// Returns iOS-specific health metrics for beacon inclusion.
    /// Added under "iosHealth" key — absent on Android beacons (no collision).
    func getSessionMetrics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        return [
            "thermalState":       thermalStateString(),
            "thermalLevel":       thermalStateLevel(),        // 0-3
            "lowPowerMode":       ProcessInfo.processInfo.isLowPowerModeEnabled,
            "memPressureCount":   memoryWarningCount,         // mirrors Android onTrimMemory count
            "hangCount":          hangCount,                  // mirrors Android ANR concept
            "processorCount":     ProcessInfo.processInfo.activeProcessorCount
        ]
    }

    func resetSession() {
        lock.lock()
        memoryWarningCount = 0
        hangCount          = 0
        sessionStartTime   = Date()
        lock.unlock()
    }

    func shutdown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        hangDetectorTimer?.cancel()
        hangDetectorTimer = nil
    }
}
