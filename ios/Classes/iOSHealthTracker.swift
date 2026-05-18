import Foundation
import UIKit

/// iOSHealthTracker — Tracks iOS-specific device health signals.
///
/// Thread-safety fix:
///   lastMainThreadPing was written from the main thread (via DispatchQueue.main.async)
///   and read from the background DispatchSourceTimer thread without any
///   synchronisation — a classic data race on a struct (Date).
///   Fix: protect lastMainThreadPing with a dedicated NSLock so both reads and
///   writes are serialised.
///
/// False-positive rate:
///   A 500ms hang threshold is very sensitive — every Flutter frame drop
///   (Choreographer skipped frames) will count.  The count is still useful as a
///   session-level heuristic, but callers should interpret it as
///   "main thread pressure events" rather than true ANR-equivalent hangs.
final class iOSHealthTracker {

    // MARK: - Singleton
    static let shared = iOSHealthTracker()
    private init() {}

    // MARK: - Constants

    // ✅ 1.2.24: cap on hangCount to prevent unbounded growth on long sessions
    // with persistent main-thread pressure. At the 250ms ping interval, a 0.5s
    // hang threshold means hangCount can grow ~2/second worst-case — 200
    // corresponds to ~100 seconds of continuous main-thread blockage, well
    // beyond any session that's still useful to debug from the metric alone.
    // Bumped from the previous implicit cap (50, observed in 1.2.21 beacons).
    private let maxHangCount: Int = 200

    // MARK: - State
    private var memoryWarningCount: Int  = 0
    private var hangCount:          Int  = 0
    private var sessionStartTime:   Date = Date()
    private var observers:          [NSObjectProtocol] = []
    private let lock       = NSLock()

    // ✅ Separate lock for the ping timestamp to avoid priority inversion
    //    between the heavy session lock and the very-frequent ping writes.
    private var lastMainThreadPing: Date = Date()
    private let pingLock = NSLock()

    // MARK: - Init

    func initialize() {
        lock.lock()
        sessionStartTime   = Date()
        memoryWarningCount = 0
        hangCount          = 0
        lock.unlock()

        pingLock.lock()
        lastMainThreadPing = Date()
        pingLock.unlock()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        let memObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.memoryWarningCount += 1
            let count = self.memoryWarningCount
            self.lock.unlock()
            OrionLogger.debug("iOSHealthTracker: ⚠️ Memory warning #\(count)")
        }

        let lpObs = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object:  nil,
            queue:   .main
        ) { _ in
            OrionLogger.debug("iOSHealthTracker: Low power mode → \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }

        let thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object:  nil,
            queue:   .main
        ) { _ in
            OrionLogger.debug("iOSHealthTracker: Thermal state → \(ProcessInfo.processInfo.thermalState.rawValue)")
        }

        observers = [memObs, lpObs, thermalObs]
        startHangDetection()
        OrionLogger.debug("iOSHealthTracker: Initialized")
    }

    // MARK: - Hang Detection

    private var hangDetectorTimer: DispatchSourceTimer?

    private func startHangDetection() {
        let pingInterval:  TimeInterval = 0.25
        let hangThreshold: TimeInterval = 0.5

        hangDetectorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            // ✅ Read last ping timestamp under its own lock — safe from background thread.
            self.pingLock.lock()
            let lastPing = self.lastMainThreadPing
            self.pingLock.unlock()

            let gap = Date().timeIntervalSince(lastPing)
            if gap > hangThreshold {
                self.lock.lock()
                // ✅ 1.2.24: cap the counter at maxHangCount. Past the cap we
                // also skip the log line to avoid spamming logs on heavy
                // main-thread pressure sessions. The ping code below MUST
                // still run regardless — skipping it would cause every
                // subsequent tick to falsely detect a hang.
                if self.hangCount < self.maxHangCount {
                    self.hangCount += 1
                    let count = self.hangCount
                    self.lock.unlock()
                    OrionLogger.debug("iOSHealthTracker: ⚠️ Main thread hang (\(Int(gap * 1000))ms) #\(count)")
                } else {
                    self.lock.unlock()
                }
            }

            // Ping the main thread — write under pingLock.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pingLock.lock()
                self.lastMainThreadPing = Date()
                self.pingLock.unlock()
            }
        }
        timer.resume()
        hangDetectorTimer = timer
    }

    // MARK: - Thermal State

    func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:    return "nominal"
        case .fair:       return "fair"
        case .serious:    return "serious"
        case .critical:   return "critical"
        @unknown default: return "unknown"
        }
    }

    func thermalStateLevel() -> Int {
        return Int(ProcessInfo.processInfo.thermalState.rawValue)
    }

    // MARK: - Session Metrics

    func getSessionMetrics() -> [String: Any] {
        lock.lock()
        let memWarn  = memoryWarningCount
        let hangs    = hangCount
        lock.unlock()

        return [
            "thermalState":     thermalStateString(),
            "thermalLevel":     thermalStateLevel(),
            "lowPowerMode":     ProcessInfo.processInfo.isLowPowerModeEnabled,
            "memPressureCount": memWarn,
            "hangCount":        hangs,
            "processorCount":   ProcessInfo.processInfo.activeProcessorCount
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