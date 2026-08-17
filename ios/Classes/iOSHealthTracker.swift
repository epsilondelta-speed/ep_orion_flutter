import Foundation
import UIKit

/// iOSHealthTracker — Tracks iOS-specific device health signals.
///
/// Thread-safety:
///   lastMainThreadActivity is written from the main thread (from the run-loop
///   observer) and read from the background DispatchSourceTimer thread, so it
///   is protected by its own NSLock, separate from the heavier session lock
///   (avoids priority inversion between the very-frequent activity writes and
///   session reads).
///
/// Hang detection (observer-based since 1.2.32):
///   A CFRunLoopObserver on the main run loop records when the main thread
///   last entered and left its work phase. A background timer samples that
///   timestamp every 250 ms; if the main thread has been continuously busy for
///   more than 500 ms it is considered hung for that interval.
///
///   IOS-01: through 1.2.31 this worked by *pinging* — the timer posted a
///   block to the main queue on every tick, so the SDK woke the main thread
///   four times a second for the entire life of the process, on every device,
///   whether or not anything was happening. Each wake pulls the main thread
///   out of mach_msg_trap, blocks the CPU from entering a deep idle state and
///   defeats timer coalescing, which is a pure battery cost in an app that is
///   otherwise sitting still.
///
///   The observer costs nothing: it fires only when the main run loop is
///   already running, so it adds zero wakeups. It is also strictly more
///   accurate than the ping, which could not distinguish "the main thread is
///   idle" from "the main thread is blocked" — both look like an unanswered
///   ping. CFRunLoopActivity.beforeWaiting tells us the run loop is parked and
///   immediately available, so an idle app can never register a hang.
///
///   The timer no longer touches the main thread at all, is suspended outright
///   while the app is backgrounded, and carries leeway so the OS can coalesce
///   its remaining background-queue wakeups.
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

    /// How often the background sampler reads the main thread's last-observed
    /// activity. Since 1.2.32 this is purely a background-queue timer — it
    /// does no main-thread work, so the rate no longer costs the app anything
    /// on the main thread.
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
    ///
    /// Largely redundant since 1.2.32, which suspends the sampler outright on
    /// didEnterBackground and resets the clock before resuming it, so no tick
    /// ever spans a suspension. Kept as the safety net for the case where the
    /// background notification does not arrive.
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

    /// When the main run loop was last observed entering or leaving work,
    /// on the monotonic uptime clock. Guarded by `pingLock`.
    ///
    /// Monotonic rather than `Date()` (1.2.32): wall clock is not monotonic,
    /// so an NTP correction or a user changing the device time stepped this
    /// value and manufactured a hang out of nothing — a 2-second forward step
    /// read as a 2-second freeze. `systemUptime` cannot step, and like
    /// `Date()` it keeps advancing while the app is backgrounded, so the
    /// suspensionCeiling / appWasBackgrounded logic below is unaffected.
    private var lastMainThreadActivity: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// True while the main run loop is parked in its wait state.
    ///
    /// The distinction the ping could never draw. An idle main thread and a
    /// blocked one both fail to answer a ping, so the old detector relied on
    /// forcing a wake to prove liveness. `beforeWaiting` proves it for free:
    /// the run loop reached the end of its work and went to sleep, so it is
    /// available right now regardless of how long it has been sitting there.
    /// While this is true no hang can be in progress, whatever the gap.
    private var mainThreadIdle = true

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
            guard let self = self else { return }
            // Reset BEFORE resuming, so the first tick after resume measures
            // from now rather than from whenever the app went away.
            self.resetPingClock()
            self.resumeHangDetection()
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

            // IOS-01: nothing on screen, nothing to freeze. Stop sampling
            // entirely rather than keeping a 4 Hz background-queue timer alive
            // for the whole time the app sits in the background.
            self.suspendHangDetection()
        }

        observers = [memObs, lpObs, thermalObs, activeObs, bgObs]
        startMainThreadObserver()
        startHangDetection()
        OrionLogger.debug("iOSHealthTracker: Initialized")
    }

    private func resetPingClock() {
        pingLock.lock()
        lastMainThreadActivity = ProcessInfo.processInfo.systemUptime
        // Assume idle until the observer says otherwise. Erring this way means
        // a missed observation produces no hang rather than a phantom one.
        mainThreadIdle     = true
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

    // MARK: - Main-thread activity observer

    private var runLoopObserver: CFRunLoopObserver?

    /// False when the observer could not be installed, in which case the
    /// detector falls back to the pre-1.2.32 main-queue ping.
    ///
    /// Guarded by `pingLock`: written on the main thread by
    /// startMainThreadObserver()/shutdown(), read by the detector on the
    /// utility queue on every tick.
    private var usingRunLoopObserver = false

    /// Install a CFRunLoopObserver on the main run loop.
    ///
    /// This is the whole of the IOS-01 fix. A run-loop observer is invoked
    /// from inside the run loop's own cycle, so it executes only when the main
    /// thread is already awake and doing something — it never causes a wakeup,
    /// and on a genuinely idle app it does not run at all.
    ///
    /// Registered in `.commonModes` rather than `.defaultMode` so it keeps
    /// observing during UITrackingRunLoopMode. That matters: hangs while the
    /// user is dragging a scroll view are the ones people actually feel, and a
    /// defaultMode-only observer would go silent for the whole gesture and
    /// report every scroll as a hang.
    @discardableResult
    private func startMainThreadObserver() -> Bool {
        if runLoopObserver != nil {
            pingLock.lock()
            let active = usingRunLoopObserver
            pingLock.unlock()
            return active
        }

        // beforeSources is the load-bearing one: CFRunLoop fires it at the top
        // of every iteration, including iterations where there is already work
        // pending and the loop never sleeps (in which case beforeWaiting and
        // afterWaiting are both skipped). It is therefore the only reliable
        // per-cycle heartbeat, and without it a busy-but-healthy app that
        // never idles would look permanently hung.
        //
        // beforeWaiting carries the idle signal. afterWaiting tightens the
        // timestamp on the wake edge.
        //
        // beforeTimers is deliberately NOT observed: it fires microseconds
        // before beforeSources in the same iteration, so it would add a main-
        // thread lock acquisition per cycle and tell us nothing new. This is a
        // fix for main-thread overhead — it should not add avoidable work of
        // its own.
        let activities: CFOptionFlags =
              CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeSources.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue

        let created: CFRunLoopObserver? = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,            // repeats
            CFIndex.min      // run ahead of other observers
        ) { [weak self] _, activity in
            guard let self = self else { return }
            // Runs on the main thread, up to three times per run-loop cycle,
            // so it must stay trivial: one clock read and two guarded writes.
            // No allocation, no logging, no Date().
            //
            // pingLock is held here for the duration of two field stores —
            // tens of nanoseconds. The detector's critical sections on the
            // utility queue are the same size, so the window in which a
            // background thread could hold this lock against the main thread
            // is far too small to matter in practice. Kept as a lock rather
            // than assuming word-sized stores are atomic, which the language
            // does not guarantee.
            let now = ProcessInfo.processInfo.systemUptime
            self.pingLock.lock()
            self.lastMainThreadActivity = now
            self.mainThreadIdle = (activity == .beforeWaiting)
            self.pingLock.unlock()
        }

        guard let observer = created else {
            OrionLogger.debug("iOSHealthTracker: run-loop observer unavailable, falling back to ping")
            pingLock.lock()
            usingRunLoopObserver = false
            pingLock.unlock()
            return false
        }

        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer

        pingLock.lock()
        usingRunLoopObserver = true
        pingLock.unlock()
        return true
    }

    // MARK: - Hang Detection

    private var hangDetectorTimer: DispatchSourceTimer?
    /// Guarded by `pingLock`. DispatchSourceTimer suspend/resume must balance
    /// exactly — an unbalanced resume traps, and releasing a suspended source
    /// crashes — so the state is tracked rather than inferred.
    private var timerSuspended = false

    private func startHangDetection() {
        teardownHangDetection()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Leeway lets the OS coalesce this with other timers instead of
        // demanding a wakeup at an exact instant. It costs nothing in
        // accuracy: hang durations are measured from observed timestamps, not
        // counted in ticks, so leeway only widens worst-case detection latency
        // from 250 ms to ~350 ms — still well inside the 500 ms threshold.
        timer.schedule(deadline:  .now() + pingInterval,
                       repeating: pingInterval,
                       leeway:    .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.pingLock.lock()
            let lastActivity = self.lastMainThreadActivity
            let idle         = self.mainThreadIdle
            let observing    = self.usingRunLoopObserver
            self.pingLock.unlock()

            // An idle run loop is a healthy one — it is parked in its wait
            // state and will service work the instant it arrives, so however
            // long it has been sitting there, the gap is not a hang. Treating
            // it as zero also closes out any hang that ended by the app simply
            // going quiet, via the recovery branch below.
            let gap: TimeInterval = (observing && idle)
                ? 0
                : ProcessInfo.processInfo.systemUptime - lastActivity

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
                // Main thread is moving again — either it reached the run
                // loop's wait state, or it cycled recently enough to be under
                // the threshold. If a hang was in progress it has now ended.
                // Record exactly one entry using the longest gap observed,
                // accurate to within one sampling interval (250 ms, plus up
                // to 100 ms of timer leeway).
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

            // IOS-01: with the observer installed there is nothing to do here.
            // The main thread reports its own liveness as a side effect of
            // work it was already doing, so the SDK never wakes it.
            //
            // The ping survives only as the fallback for the case where the
            // observer could not be created, which should not happen on a
            // normal UIKit app but must not leave hang detection dead.
            if !observing {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.pingLock.lock()
                    self.lastMainThreadActivity = now
                    self.pingLock.unlock()
                }
            }
        }
        timer.resume()

        pingLock.lock()
        timerSuspended = false
        pingLock.unlock()

        hangDetectorTimer = timer
    }

    /// Stop sampling while the app is backgrounded.
    private func suspendHangDetection() {
        guard let timer = hangDetectorTimer else { return }
        pingLock.lock()
        let alreadySuspended = timerSuspended
        timerSuspended = true
        pingLock.unlock()

        if !alreadySuspended { timer.suspend() }
    }

    private func resumeHangDetection() {
        guard let timer = hangDetectorTimer else { return }
        pingLock.lock()
        let wasSuspended = timerSuspended
        timerSuspended = false
        pingLock.unlock()

        if wasSuspended { timer.resume() }
    }

    /// Cancel and release the timer safely.
    ///
    /// A suspended DispatchSourceTimer must be resumed before it is released —
    /// deallocating one while suspended is a hard crash in libdispatch
    /// ("Release of a suspended object"). Since 1.2.32 the timer really can be
    /// suspended at teardown time (backgrounded app, then shutdown), so this
    /// has to be ordered rather than a bare cancel().
    private func teardownHangDetection() {
        guard let timer = hangDetectorTimer else { return }
        hangDetectorTimer = nil

        pingLock.lock()
        let wasSuspended = timerSuspended
        timerSuspended = false
        pingLock.unlock()

        timer.setEventHandler {}
        timer.cancel()
        if wasSuspended { timer.resume() }
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

        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
            pingLock.lock()
            usingRunLoopObserver = false
            pingLock.unlock()
        }

        teardownHangDetection()
    }
}
