import Foundation

/// MemoryMetricsTracker — Session-level memory growth tracking.
/// Mirrors MemoryMetricsTracker.kt exactly.
///
/// Thread-safety fix: all mutable state is now guarded by NSLock.
/// Previously startNewSession(), onScreenTransition(), and getSessionMetrics()
/// read/wrote shared vars (peakBytes, currentBytes, samples, etc.) without any
/// synchronization.  onScreenTransition() is called from FlutterSendData
/// (platform thread) while getSessionMetrics() can be called concurrently
/// from the same path — a data race.
///
/// Sampling kill-switch: onScreenTransition() returns early when
/// iOSSamplingManager.shared.isTrackingEnabled is false, saving CPU when the
/// remote kill-switch is active.
final class MemoryMetricsTracker {

    // MARK: - Singleton
    static let shared = MemoryMetricsTracker()
    private init() {}

    // MARK: - Constants
    private let tag            = "MemoryMetrics"
    private let minDurationMs: Double = 36_000
    private let sessionTimeoutMs: Double = 30 * 60 * 1000
    private let maxSamples     = 100

    // MARK: - Session state (guarded by lock)
    private var startBytes:   Int64  = -1
    private var startTime:    Double = 0
    private var peakBytes:    Int64  = 0
    private var currentBytes: Int64  = 0
    private var samples:      Int    = 0
    private var active:       Bool   = false
    private let lock = NSLock()

    // MARK: - Init

    func initialize() {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        startNewSessionLocked()
        OrionLogger.debug("\(tag): Initialized")
    }

    func startNewSession() {
        lock.lock()
        defer { lock.unlock() }
        startNewSessionLocked()
    }

    // Must be called while lock is held.
    private func startNewSessionLocked() {
        let bytes    = residentMemoryBytes()
        startBytes   = bytes
        startTime    = nowMs()
        peakBytes    = bytes
        currentBytes = bytes
        samples      = 1
        active       = true
        OrionLogger.debug("\(tag): Session started (\(formatMB(bytes)))")
    }

    // MARK: - Sample on screen transition

    func onScreenTransition() {
        // ✅ Sampling kill-switch: skip native memory sampling when disabled.
        if !iOSSamplingManager.shared.isTrackingEnabled {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if !active {
            startNewSessionLocked()
            return
        }

        // Auto-reset after 30 minutes (mirrors Android SESSION_TIMEOUT_MS).
        let sessionDuration = nowMs() - startTime
        if sessionDuration > sessionTimeoutMs {
            OrionLogger.debug("\(tag): Session timeout, resetting")
            startNewSessionLocked()
            return
        }

        // Auto-reset after 100 samples (mirrors Android MAX_SAMPLES).
        if samples >= maxSamples {
            OrionLogger.debug("\(tag): Max samples reached, resetting")
            startNewSessionLocked()
            return
        }

        let bytes = residentMemoryBytes()
        currentBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        samples += 1
    }

    // MARK: - Session Metrics

    func getSessionMetrics() -> [String: Any] {
        lock.lock()
        if !active { startNewSessionLocked() }

        let bytes = residentMemoryBytes()
        currentBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }

        let startMB  = toMB(startBytes)
        let curMB    = toMB(currentBytes)
        let peakMB   = toMB(peakBytes)
        let growthMB = startBytes > 0 ? curMB - startMB : 0.0

        let durationMs = nowMs() - startTime
        let hours      = durationMs / 3_600_000.0
        let growthPerHour: Double = (durationMs > minDurationMs && hours > 0)
            ? growthMB / hours
            : 0.0

        let result: [String: Any] = [
            "startMB":       round2(startMB),
            "curMB":         round2(curMB),
            "peakMB":        round2(peakMB),
            "growthMB":      round2(growthMB),
            "growthPerHour": round2(growthPerHour),
            "samples":       samples
        ]
        lock.unlock()
        return result
    }

    func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        startBytes   = -1
        startTime    = 0
        peakBytes    = 0
        currentBytes = 0
        samples      = 0
        active       = false
        OrionLogger.debug("\(tag): Session reset")
    }

    func isSessionActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func getCurrentMemoryMB() -> Double {
        return toMB(residentMemoryBytes())
    }

    // MARK: - iOS Memory API

    private func residentMemoryBytes() -> Int64 {
        var info  = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int64(info.resident_size)
    }

    // MARK: - Helpers

    private func toMB(_ bytes: Int64) -> Double {
        return bytes > 0 ? Double(bytes) / 1_048_576.0 : -1.0
    }

    private func formatMB(_ bytes: Int64) -> String {
        return bytes > 0 ? String(format: "%.1f MB", toMB(bytes)) : "N/A"
    }

    private func round2(_ v: Double) -> Double {
        guard v >= 0 else { return v }
        return (v * 100).rounded() / 100
    }

    private func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000.0
    }
}
