import Foundation
import UIKit

/// iOSHealthTracker — Tracks iOS-specific device health signals.
///
/// Thread-safety:
///   lastMainThreadPing is written from the main thread (via
///   DispatchQueue.main.async) and read from the background
///   DispatchSourceTimer thread, so it is protected by its own NSLock,
///   separate from the heavier session lock (avoids priority inversion
///   between the very-frequent ping writes and session reads).
///
/// Hang detection (detail added 1.2.28):
///   A background timer pings the main thread every 250 ms. If the gap since
///   the last successful ping exceeds 500 ms, the main thread is considered
///   hung for that interval.
///
///   Prior to 1.2.28 only a count was kept — `hangCount: 3` told a developer
///   the app froze but nothing about where or how badly, which is not
///   actionable. The tracker now retains per-hang duration, timestamp and the
///   screen that was showing at the time, and reports aggregates plus the
///   worst offenders in `hangDetail`.
///
/// False-positive rate:
///   The 500 ms threshold is sensitive — a dropped-frame burst counts. Read
///   these as "main thread pressure events" rather than ANR-equivalent hangs.
///   Use `hangDetail.worstMs` and the bucket distribution to separate ordinary
///   jank (500 ms–1 s) from genuinely user-visible freezes (2 s+).
final class iOSHealthTracker {

    // MARK: - Singleton
    static let shared = iOSHealthTracker()
    private init() {}

    // MARK: - Tunables

    private let pingInterval:  TimeInterval = 0.25
    private let hangThreshold: TimeInterval = 0.5

    /// Gaps longer than this are treated as app suspension, not a hang.
    ///
    /// When iOS suspends a backgrounded process, both the timer and the main
    /// thread stop. On resume the first tick sees a gap equal to the entire
    /// background duration, which pre-1.2.28 was counted as a hang — a
    /// 5-minute background produced a bogus 300,000 ms "hang". Anything above
    /// this ceiling is discarded, and didBecomeActive also resets the ping
    /// clock so the first post-resume tick starts fresh.
    private let suspensionCeiling: TimeInterval = 10.0

    /// Upper bound on retained hang records. Hangs are rare compared to
    /// frames, so this is generous; when full, a new hang only displaces the
    /// shortest retained one, keeping the worst offenders.
    private let maxRetainedHangs = 50

    /// How many hangs are emitted in the beacon (worst first).
    private let maxReportedHangs = 5

    // MARK: - State

    private var memoryWarningCount: Int  = 0
    private var hangCount:          Int  = 0
    private var sessionStartTime:   Date = Date()
    private var observers:          [NSObjectProtocol] = []
    private let lock       = NSLock()

    private var lastMainThreadPing: Date = Date()
    private let pingLock = NSLock()

    /// In-progress hang state. Guarded by `pingLock` — written by the
    /// detector's timer thread and read/reset by getSessionMetrics() on the
    /// beacon path, so it is genuinely shared. `pingLock` is always released
    /// before recordHang() acquires `lock`, so the two never nest.
    ///
    /// While the main thread is blocked it cannot service the ping, so every
    /// tick sees an ever-growing gap. Recording on each tick counts ONE hang
    /// many times — a 6 s block produced 24 records of 250, 500 … 6000 ms,
    /// inflating hangCount and pushing pctOfSession above 100%. We instead
    /// hold the running maximum and record a single entry when the main
    /// thread recovers.
    private var hangInProgress = false
    private var hangMaxGapMs   = 0

    /// True while the app has been backgrounded and not yet foregrounded.
    ///
    /// SDK-14: the suspensionCeiling alone cannot tell a real 30-second hang
    /// from a 30-second suspension, so it discarded both — which inverted the
    /// data. A screen that hung for 30 s produced ZERO records and looked
    /// clean, while a screen that hung for 6 s looked bad: the worst screens
    /// in an app were the ones that disappeared.
    ///
    /// Tracking background state resolves it. A gap above the ceiling that
    /// spans a background transition is suspension; one that occurs entirely
    /// in the foreground is a genuine hang, recorded with
    /// `ceilingTruncated: true` so consumers know the duration is a floor.
    private var appWasBackgrounded = false

    /// Screen captured when a hang STARTS, not when it is recorded.
    ///
    /// SDK-16: a hang still running when the user navigates is flushed during
    /// the next screen's beacon assembly, ~100 ms after `onFlutterScreenStart`
    /// has already moved `currentScreen` forward. It was therefore attributed
    /// to the screen the user navigated TO, not the one that hung — and
    /// navigation transitions are exactly where hangs cluster.
    private var hangStartScreen: String = "UnknownScreen"

    /// Mirror of `currentScreen` guarded by `pingLock` rather than `lock`.
    ///
    /// The 250 ms detector tick needs the screen name to stamp a hang's start,
    /// but reading `currentScreen` would mean taking `lock` four times a
    /// second on a path that already holds `pingLock` — lock nesting on the
    /// hot path. Mirroring costs one extra assignment per screen change.
    private var detectorScreen: String = "UnknownScreen"

    /// Session this tracker's counters belong to.
    ///
    /// SDK-22: `resetSession()` exists but nothing ever called it, while
    /// `SessionManager.getSessionId()` rotates lazily after 30 minutes idle.
    /// So counters accumulated across session boundaries:
    ///
    ///   * a hang recorded in session S1 was re-reported in every later
    ///     beacon, including ones stamped S2 — the backend's `(sesId, ts)`
    ///     dedupe then saw the same hang twice, once per session
    ///   * `sessionStartTime` never moved, so `pctOfSession` divided by time
    ///     since app launch rather than since session start, under-reporting
    ///     severity on long-lived processes
    ///
    /// nil until the first beacon, so the first read adopts rather than
    /// resets.
    private var trackedSessionId: String? = nil

    /// One detected main-thread hang.
    private struct HangRecord {
        let durationMs:       Int
        let epochMs:          Int64
        let screen:           String
        /// True when the gap exceeded suspensionCeiling while the app was in
        /// the foreground — the duration is then a floor, not an exact value.
        let ceilingTruncated: Bool
    }
    private var hangs: [HangRecord] = []

    /// Screen visible when a hang occurs. Written from the main thread by the
    /// plugin on every screen start, read from the detector's background
    /// thread — guarded by `lock`.
    private var currentScreen: String = "UnknownScreen"

    // MARK: - Init

    func initialize() {
        lock.lock()
        sessionStartTime   = Date()
        memoryWarningCount = 0
        hangCount          = 0
        hangs.removeAll()
        lock.unlock()

        resetPingClock()

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
            OrionLogger.debug("iOSHealthTracker: Memory warning #\(count)")
        }

        let lpObs = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object:  nil,
            queue:   .main
        ) { _ in
            OrionLogger.debug("iOSHealthTracker: Low power mode -> \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }

        let thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object:  nil,
            queue:   .main
        ) { _ in
            OrionLogger.debug("iOSHealthTracker: Thermal state -> \(ProcessInfo.processInfo.thermalState.rawValue)")
        }

        // 1.2.28: reset the ping clock when the app returns to the foreground
        // so the first tick after resume doesn't measure the background
        // duration as a hang.
        let activeObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            self?.resetPingClock()
        }

        // SDK-14: mark that a suspension window has begun, so an
        // above-ceiling gap can be attributed to suspension rather than
        // discarded blindly.
        let bgObs = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.pingLock.lock()
            self.appWasBackgrounded = true
            self.pingLock.unlock()
        }

        observers = [memObs, lpObs, thermalObs, activeObs, bgObs]
        startHangDetection()
        OrionLogger.debug("iOSHealthTracker: Initialized")
    }

    private func resetPingClock() {
        pingLock.lock()
        lastMainThreadPing = Date()
        // Any hang measurement spanning the reset is invalid.
        hangInProgress     = false
        hangMaxGapMs       = 0
        appWasBackgrounded = false
        pingLock.unlock()
    }

    // MARK: - Screen context

    /// Called by the plugin on every Flutter screen start so hang records can
    /// name the screen the user was on. Without this a hang report says only
    /// "the app froze for 2s", which is not actionable.
    func updateCurrentScreen(_ screen: String) {
        lock.lock()
        currentScreen = screen
        lock.unlock()

        // Mirror under pingLock so the detector can stamp a hang's start
        // screen without nesting locks. Sequential, never nested.
        pingLock.lock()
        detectorScreen = screen
        pingLock.unlock()
    }

    // MARK: - Hang Detection

    private var hangDetectorTimer: DispatchSourceTimer?

    private func startHangDetection() {
        hangDetectorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.pingLock.lock()
            let lastPing = self.lastMainThreadPing
            self.pingLock.unlock()

            let gap = Date().timeIntervalSince(lastPing)

            if gap > self.hangThreshold {
                self.pingLock.lock()
                if gap > self.suspensionCeiling {
                    // SDK-14: above the ceiling, background state decides.
                    let wasBackgrounded = self.appWasBackgrounded
                    let ceilScreen      = self.hangInProgress ? self.hangStartScreen
                                                             : self.detectorScreen
                    self.hangInProgress = false
                    self.hangMaxGapMs   = 0
                    self.pingLock.unlock()

                    if wasBackgrounded {
                        // Genuine suspension — the timer and main thread were
                        // both stopped by iOS. Discard.
                        OrionLogger.debug("iOSHealthTracker: ignoring \(Int(gap))s gap (app suspension, not a hang)")
                    } else {
                        // App never left the foreground, so this is a real
                        // hang that simply exceeded the ceiling. Record it
                        // rather than losing the worst hangs in the app.
                        OrionLogger.debug("iOSHealthTracker: long foreground hang \(Int(gap))s (ceiling-truncated)")
                        self.recordHang(durationMs: Int(gap * 1000),
                                        ceilingTruncated: true,
                                        screenOverride: ceilScreen)
                    }
                } else {
                    // Hang ongoing. Track the largest gap seen; do NOT record
                    // yet — the hang has not finished and its true duration
                    // is still growing.
                    if !self.hangInProgress {
                        // SDK-16: stamp the screen at hang START. By flush
                        // time the user may already be on the next screen.
                        self.hangStartScreen = self.detectorScreen
                    }
                    self.hangInProgress = true
                    self.hangMaxGapMs   = max(self.hangMaxGapMs, Int(gap * 1000))
                    self.pingLock.unlock()
                }
            } else {
                // Main thread serviced the ping again — if a hang was in
                // progress it has now ended. Record exactly one entry using
                // the longest gap observed, accurate to within one ping
                // interval (250 ms).
                self.pingLock.lock()
                let wasInHang = self.hangInProgress
                let duration  = self.hangMaxGapMs
                let screen    = self.hangStartScreen
                self.hangInProgress = false
                self.hangMaxGapMs   = 0
                self.pingLock.unlock()

                // recordHang takes `lock`; pingLock is already released.
                if wasInHang && duration > 0 {
                    self.recordHang(durationMs: duration, screenOverride: screen)
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

    private func recordHang(durationMs: Int,
                            ceilingTruncated: Bool = false,
                            screenOverride: String? = nil) {
        lock.lock()
        hangCount += 1
        let count  = hangCount
        // Prefer the screen captured when the hang started (SDK-16).
        let screen = screenOverride ?? currentScreen

        let record = HangRecord(
            durationMs:       durationMs,
            epochMs:          Int64(Date().timeIntervalSince1970 * 1000),
            screen:           screen,
            ceilingTruncated: ceilingTruncated
        )

        if hangs.count < maxRetainedHangs {
            hangs.append(record)
        } else if let minIdx = hangs.indices.min(by: { hangs[$0].durationMs < hangs[$1].durationMs }),
                  hangs[minIdx].durationMs < durationMs {
            // Buffer full — displace the shortest retained hang so the worst
            // offenders survive.
            hangs[minIdx] = record
        }
        lock.unlock()

        OrionLogger.debug("iOSHealthTracker: Main thread hang (\(durationMs)ms) #\(count) on \(screen)")
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

    /// Beacon path. MUTATING — flushes any in-progress hang before reading,
    /// so a screen exited mid-hang still reports it.
    ///
    /// SDK-04: use `peekSessionMetrics()` for anything that is logically a
    /// read. A host app polling a mutating "getter" inflates its own hang
    /// counts at the polling rate.
    func getSessionMetrics() -> [String: Any] {
        // Rotation check FIRST. If the session rotated, any in-progress hang
        // spans the boundary and is invalid — resetIfSessionRotated clears
        // hangInProgress, so the flush below correctly finds nothing pending.
        // Flushing first would record a hang that snapshot() then discards.
        resetIfSessionRotated()

        pingLock.lock()
        let pendingHang   = hangInProgress ? hangMaxGapMs : 0
        let pendingScreen = hangStartScreen
        hangInProgress    = false
        hangMaxGapMs      = 0
        pingLock.unlock()
        // SDK-16: this is THE path that was mis-attributing. The flush happens
        // during the next screen's beacon assembly, so without the captured
        // start screen the hang would be stamped with the wrong one.
        if pendingHang > 0 {
            recordHang(durationMs: pendingHang, screenOverride: pendingScreen)
        }

        return snapshot()
    }

    /// Pure read — no flush, no mutation, no `pingLock`.
    ///
    /// Used by the public `getRuntimeMetrics()` API (SDK-04) and by the crash
    /// handler (SDK-11), where taking a second lock on an arbitrary thread
    /// during termination risks losing the crash beacon entirely.
    func peekSessionMetrics() -> [String: Any] {
        return snapshot()
    }

    /// Reset counters if the session rotated since the last read.
    ///
    /// Called at the top of every metrics read. Rotation is detected rather
    /// than pushed because SessionManager has no rotation callback — it mints
    /// a new id lazily inside `getSessionId()`.
    private func resetIfSessionRotated() {
        let sid = SessionManager.getSessionId()

        lock.lock()
        let previous = trackedSessionId
        trackedSessionId = sid
        guard let previous = previous, previous != sid else {
            lock.unlock()
            return
        }
        // Rotated: this beacon belongs to a new session, so anything counted
        // under the old one has already been reported and must not carry over.
        memoryWarningCount = 0
        hangCount          = 0
        hangs.removeAll()
        sessionStartTime   = Date()
        lock.unlock()

        // Any in-progress hang measurement spans the boundary and is invalid.
        pingLock.lock()
        hangInProgress = false
        hangMaxGapMs   = 0
        pingLock.unlock()

        OrionLogger.debug("iOSHealthTracker: session rotated, counters reset")
    }

    private func snapshot() -> [String: Any] {
        // Idempotent: getSessionMetrics() already called this, and the second
        // call short-circuits because trackedSessionId now matches. Kept here
        // so peekSessionMetrics() — which does not flush — is also protected.
        resetIfSessionRotated()

        lock.lock()
        let memWarn      = memoryWarningCount
        let hangsTotal   = hangCount
        let records      = hangs
        let sessionStart = sessionStartTime
        lock.unlock()

        var out: [String: Any] = [
            "thermalState":     thermalStateString(),
            "thermalLevel":     thermalStateLevel(),
            "lowPowerMode":     ProcessInfo.processInfo.isLowPowerModeEnabled,
            "memPressureCount": memWarn,
            "hangCount":        hangsTotal,          // unchanged — back-compat
            "processorCount":   ProcessInfo.processInfo.activeProcessorCount
        ]

        // 1.2.28: hang detail. Omitted entirely when no hangs occurred, so
        // healthy sessions produce a beacon identical in size to 1.2.27.
        if !records.isEmpty {
            out["hangDetail"] = buildHangDetail(records, sessionStart: sessionStart)
        }

        return out
    }

    private func buildHangDetail(_ records: [HangRecord], sessionStart: Date) -> [String: Any] {
        let durations = records.map { $0.durationMs }
        let totalMs   = durations.reduce(0, +)
        let worstMs   = durations.max() ?? 0
        let avgMs     = durations.isEmpty ? 0 : totalMs / durations.count

        // Severity buckets — lets a dashboard separate ordinary jank from
        // user-visible freezes without shipping every raw duration.
        var small = 0, medium = 0, large = 0, xlarge = 0
        for d in durations {
            switch d {
            case ..<1000:  small  += 1   // 500ms-1s · felt as jank
            case ..<2000:  medium += 1   // 1-2s     · noticeable stall
            case ..<5000:  large  += 1   // 2-5s     · user-visible freeze
            default:       xlarge += 1   // 5s+      · perceived as a hang
            }
        }

        // Hang time as a share of session duration — the single best severity
        // signal, since 3 hangs in 10s is very different from 3 in 10min.
        let sessionMs = max(1, Int(Date().timeIntervalSince(sessionStart) * 1000))
        // Clamped at 100: hang time cannot exceed session time, so a value
        // above it always indicates a measurement fault rather than a real
        // reading. Pre-1.2.30 data shows values like 471% caused by a single
        // hang being counted once per 250 ms tick.
        let pct = min(100.0, (Double(totalMs) / Double(sessionMs)) * 100.0)

        let top = records
            .sorted { $0.durationMs > $1.durationMs }
            .prefix(maxReportedHangs)
            .map { r -> [String: Any] in
                var e: [String: Any] = [
                    "durMs":  r.durationMs,
                    "ts":     r.epochMs,
                    "screen": r.screen
                ]
                // Only present when true, so ordinary hangs stay byte-identical.
                if r.ceilingTruncated { e["ceilingTruncated"] = true }
                return e
            }

        return [
            "totMs":        totalMs,
            "worstMs":      worstMs,
            "avgMs":        avgMs,
            "pctOfSession": (pct * 100).rounded() / 100,   // 2dp
            "buckets":      ["s": small, "m": medium, "l": large, "xl": xlarge],
            "top":          Array(top)
        ]
    }

    func resetSession() {
        lock.lock()
        memoryWarningCount = 0
        hangCount          = 0
        hangs.removeAll()
        sessionStartTime   = Date()
        lock.unlock()
        resetPingClock()
    }

    func shutdown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        hangDetectorTimer?.cancel()
        hangDetectorTimer = nil
    }
}
