import Foundation

/// MemoryMetricsTracker — Session-level memory growth tracking.
/// Mirrors MemoryMetricsTracker.kt exactly.
final class MemoryMetricsTracker {

    // MARK: - Singleton
    static let shared = MemoryMetricsTracker()
    private init() {}

    // MARK: - Constants
    private let tag = "MemoryMetrics"
    private let minDurationMs: Double = 36_000  // 36 sec minimum for growth rate

    // MARK: - Session state
    private var startBytes:   Int64  = -1
    private var startTime:    Double = 0
    private var peakBytes:    Int64  = 0
    private var currentBytes: Int64  = 0
    private var samples:      Int    = 0
    private var active:       Bool   = false

    // MARK: - Init

    func initialize() {
        guard !active else { return }
        startNewSession()
        OrionLogger.debug("\(tag): Initialized")
    }

    func startNewSession() {
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
        guard active else { startNewSession(); return }
        let bytes = residentMemoryBytes()
        currentBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        samples += 1
    }

    // MARK: - Session Metrics

    func getSessionMetrics() -> [String: Any] {
        if !active { startNewSession() }

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

        return [
            "startMB":       round2(startMB),
            "curMB":         round2(curMB),
            "peakMB":        round2(peakMB),
            "growthMB":      round2(growthMB),
            "growthPerHour": round2(growthPerHour),
            "samples":       samples
        ]
    }

    func resetSession() {
        startBytes   = -1
        startTime    = 0
        peakBytes    = 0
        currentBytes = 0
        samples      = 0
        active       = false
        OrionLogger.debug("\(tag): Session reset")
    }

    func isSessionActive() -> Bool { return active }
    func getCurrentMemoryMB() -> Double { return toMB(residentMemoryBytes()) }

    // MARK: - iOS Memory API
    // mach_task_basic_info.resident_size = physical RAM used by this process

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

    // ✅ Fixed round2 — no more 153.05000000000001 floating point ugliness
    private func round2(_ v: Double) -> Double {
        guard v >= 0 else { return v }
        return (v * 100).rounded() / 100
    }

    private func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000.0
    }
}
