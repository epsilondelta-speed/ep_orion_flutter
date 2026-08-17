import Foundation
import UIKit

/// WakeLockTracker — Full iOS implementation.
/// Mirrors WakeLockTracker.kt exactly.
///
/// Thread-safety:
///   UIApplication.shared.beginBackgroundTask / endBackgroundTask MUST be
///   called on the main thread. Those hops are made without ever holding
///   `lock`.
///
/// IOS-04 (1.2.32) — five defects fixed here, all in the acquire/release pair:
///
///   1. DEADLOCK. acquire() took `lock`, then — off the main thread — did
///      `DispatchQueue.main.async { ... }` followed by `sema.wait()`, i.e. it
///      blocked on the main queue *while holding the tracker lock*. The main
///      thread routinely takes that same lock: onAppForeground/Background from
///      lifecycle notifications, and getSessionMetrics() on every screen
///      beacon via FlutterSendData. Background thread waits for main, main
///      waits for the lock — permanent app freeze.
///
///      Not reachable today, and worth being precise about why: acquire()'s
///      only caller is the Flutter method channel, which is registered with no
///      task queue and so delivers on the main thread, taking the other
///      branch. It becomes live the moment anything calls acquire() off the
///      main thread. The semaphore is gone entirely; nothing blocks now.
///
///   2. Use-before-assignment on the background task id. The expiry handler
///      captured a TaskBox whose `id` was assigned by the *caller* from
///      beginBackgroundTask's return value. An expiry firing before that
///      assignment called endBackgroundTask(.invalid) — leaving the real task
///      un-ended, which iOS punishes by killing the app. The handler now
///      resolves the id from tracker state instead of a shared box.
///
///   3. Expiry left the tracker inconsistent. The handler ended the OS task
///      but never removed the entry from activeWakeLocks, so the tracker still
///      believed the lock was held and a later release() called
///      endBackgroundTask on an already-ended identifier. Expiry now goes
///      through the normal release path.
///
///   4. Stale timeout releases. The timeout scheduled by acquire() called
///      release(tag:) unconditionally, so acquire("X", timeout: 1s) → release
///      → re-acquire("X") had the first timer tear down the *second* lock.
///      Acquisitions now carry a generation and a timeout only releases its
///      own.
///
///   5. Split accounting in release(). It locked, unlocked to dispatch, then
///      re-locked to fold the metrics — so a concurrent acquire of the same
///      tag could interleave between the two critical sections and have the
///      old hold's numbers applied on top of it. Removal and accounting now
///      happen in one critical section, with the UIKit call after it.
///
/// Durations are measured on the monotonic uptime clock rather than
/// Date(). Only elapsed times are ever reported (totalMs / bgMs / maxMs — no
/// absolute timestamp leaves this file), and wall clock is not monotonic: an
/// NTP correction mid-hold produced a nonsense duration, including negative
/// ones that then poisoned maxMs.
///
/// Sampling kill-switch:
///   trackAcquire() / trackRelease() return early when
///   iOSSamplingManager.shared.isTrackingEnabled is false.
///
/// Active-lock maxMs fix (Issue 3): getSessionMetrics() previously emitted
/// `maxMs` from `metrics.maxHeldMs` — but that field is only updated in
/// release(). For a currently-active lock that has never been released,
/// `metrics.maxHeldMs` is 0, so the beacon reported `maxMs: 0` even when
/// the lock had been held for several seconds. Now we compute the effective
/// max as `max(metrics.maxHeldMs, currentHoldDuration)` for active locks,
/// and apply the same correction at the top-level summary maxMs.
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
        /// Distinguishes successive acquisitions of the same tag, so a timeout
        /// or an expiry handler belonging to an earlier hold cannot tear down
        /// a later one that happens to share the tag.
        let generation:      UInt64
        /// IOS-06: the pending auto-release, so it can be cancelled when the
        /// lock is released early instead of sitting on a global queue until
        /// its deadline. `asyncAfter` cannot be cancelled; a DispatchWorkItem
        /// can.
        var timeoutWork:     DispatchWorkItem? = nil
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
    private var nextGeneration:   UInt64 = 0
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
                totalBgTimeMs     += bgDuration
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
                info.bgStartTimeMs   = now
                activeWakeLocks[tag] = info
            }
        }
        isAppInForeground = false
        OrionLogger.debug("WakeLockTracker: App backgrounded")
    }

    // MARK: - Acquire

    @discardableResult
    func acquire(tag: String, timeoutMs: Int? = nil) -> Bool {
        // Step 1 — register the acquisition. Lock held for bookkeeping only:
        // no UIKit, no dispatch, no waiting inside this critical section.
        lock.lock()
        guard activeWakeLocks[tag] == nil else {
            lock.unlock()
            OrionLogger.debug("WakeLockTracker: '\(tag)' already held")
            return true
        }

        let now        = nowMs()
        let generation = nextGeneration
        nextGeneration &+= 1

        activeWakeLocks[tag] = ActiveWakeLockInfo(
            tag:             tag,
            type:            WakeLockTracker.typePartial,
            acquireTimeMs:   now,
            timeoutMs:       timeoutMs,
            wasInForeground: isAppInForeground,
            bgStartTimeMs:   isAppInForeground ? nil : now,
            generation:      generation
        )

        if sessionMetricsMap[tag] == nil {
            sessionMetricsMap[tag] = WakeLockSessionMetrics(tag: tag)
        }
        if var metrics = sessionMetricsMap[tag] {
            metrics.acquireCount += 1
            sessionMetricsMap[tag] = metrics
        }
        totalAcquireCount += 1
        lock.unlock()

        // Step 2 — ask iOS for the background task, on the main thread, with
        // no lock held. When we are already on the main thread this is
        // synchronous and the return value is exact; otherwise it is handed to
        // the main queue and we report success optimistically rather than
        // blocking the caller. That optimism is the deliberate trade for
        // removing the deadlock, and it costs nothing today: the only caller
        // is the method channel, which is already on the main thread.
        let started: Bool
        if Thread.isMainThread {
            started = startBackgroundTask(tag: tag, generation: generation)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startBackgroundTask(tag: tag, generation: generation)
            }
            started = true
        }

        // Step 3 — timeout, scoped to THIS acquisition and cancellable.
        //
        // IOS-06: this used to be a bare asyncAfter, which cannot be cancelled.
        // A lock released early left its block queued until the deadline,
        // holding the closure and the captured tag the whole time — so a long
        // timeout on a frequently re-acquired tag accumulated them. A
        // DispatchWorkItem is cancelled by release(), so the block and its
        // captures are dropped as soon as the lock goes away.
        if let timeout = timeoutMs {
            let work = DispatchWorkItem { [weak self] in
                self?.release(tag: tag, expectedGeneration: generation)
            }

            // File it against the acquisition BEFORE scheduling, so a release
            // racing this cannot miss it. If the lock has already gone (or was
            // superseded), cancel immediately rather than schedule an orphan.
            lock.lock()
            if var info = activeWakeLocks[tag], info.generation == generation {
                info.timeoutWork     = work
                activeWakeLocks[tag] = info
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeout),
                                                  execute: work)
            } else {
                lock.unlock()
                work.cancel()
            }
        }

        OrionLogger.debug("WakeLockTracker: locked '\(tag)'")
        return started
    }

    /// Starts the OS background task and files its identifier against the
    /// acquisition that asked for it. MUST be called on the main thread; must
    /// NOT be called with `lock` held.
    @discardableResult
    private func startBackgroundTask(tag: String, generation: UInt64) -> Bool {
        let taskId = UIApplication.shared.beginBackgroundTask(withName: tag) { [weak self] in
            // iOS calls the expiry handler on the main thread. Route it through
            // release() so the OS task is ended AND the tracker's own state is
            // cleaned up — ending the task alone used to leave activeWakeLocks
            // holding an entry whose identifier was already dead.
            self?.release(tag: tag, expectedGeneration: generation)
        }

        guard taskId != UIBackgroundTaskIdentifier.invalid else { return false }

        // The expiry handler cannot have run yet: it is delivered on the main
        // thread, which is currently executing this function, so it can only
        // fire once we return to the run loop. That is what makes filing the
        // identifier here race-free — unlike the previous shared TaskBox,
        // which the handler could read before the caller had written it.
        lock.lock()
        if var info = activeWakeLocks[tag], info.generation == generation {
            info.bgTaskId        = taskId
            activeWakeLocks[tag] = info
            lock.unlock()
            return true
        }
        lock.unlock()

        // Released, or superseded by a newer acquisition of the same tag,
        // before the identifier landed. End it now rather than leak a
        // background task iOS will eventually kill the app over.
        UIApplication.shared.endBackgroundTask(taskId)
        return false
    }

    // MARK: - Release

    /// - Parameter expectedGeneration: when non-nil, the release only applies
    ///   if the currently-held lock is that exact acquisition. Used by the
    ///   timeout timer and the background-task expiry handler, both of which
    ///   can fire after their own lock was already released and a new one
    ///   acquired under the same tag.
    func release(tag: String, expectedGeneration: UInt64? = nil) {
        // Removal AND accounting in one critical section. Splitting them (as
        // this did before, to dispatch the UIKit call in between) let a
        // concurrent acquire of the same tag slip in and receive the previous
        // hold's numbers.
        lock.lock()
        guard let info = activeWakeLocks[tag] else {
            lock.unlock()
            OrionLogger.debug("WakeLockTracker: release called for unknown '\(tag)'")
            return
        }
        if let expected = expectedGeneration, info.generation != expected {
            lock.unlock()
            OrionLogger.debug("WakeLockTracker: stale release ignored for '\(tag)'")
            return
        }
        activeWakeLocks.removeValue(forKey: tag)

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

        let bgTaskId    = info.bgTaskId
        let timeoutWork = info.timeoutWork
        lock.unlock()

        // IOS-06: drop the pending auto-release. Without this the block sat on
        // a global queue until its deadline, retaining its closure and the
        // captured tag — and then fired against a lock that no longer existed.
        // Cancelling outside the lock: DispatchWorkItem.cancel() is cheap, but
        // nothing that touches libdispatch belongs in a critical section here.
        //
        // Harmless when release() IS the timeout firing — cancelling an
        // already-executing work item is a no-op.
        timeoutWork?.cancel()

        // ✅ endBackgroundTask must run on the main thread — and outside the
        //    lock, always. Called inline when we are already there so the task
        //    ends immediately rather than a run-loop turn later.
        if bgTaskId != UIBackgroundTaskIdentifier.invalid {
            if Thread.isMainThread {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            } else {
                DispatchQueue.main.async {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }
        }

        OrionLogger.debug("WakeLockTracker: released '\(tag)' after \(Int(heldMs))ms\(isStuck ? " STUCK" : "")")
    }

    // MARK: - Manual Tracking (sampling-gated)

    func trackAcquire(tag: String, timeoutMs: Int? = nil) {
        // ✅ Sampling kill-switch
        guard iOSSamplingManager.shared.isTrackingEnabled else { return }

        lock.lock()
        defer { lock.unlock() }
        guard activeWakeLocks[tag] == nil else { return }

        let now = nowMs()
        let generation = nextGeneration
        nextGeneration &+= 1

        // No background task: manual tracking observes a wake lock the host
        // app owns, it does not take one out. bgTaskId stays .invalid, so
        // release() skips the endBackgroundTask hop entirely.
        activeWakeLocks[tag] = ActiveWakeLockInfo(
            tag:             tag,
            type:            WakeLockTracker.typePartial,
            acquireTimeMs:   now,
            timeoutMs:       timeoutMs,
            wasInForeground: isAppInForeground,
            bgStartTimeMs:   isAppInForeground ? nil : now,
            generation:      generation
        )

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

    func trackRelease(tag: String) {
        // ✅ Sampling kill-switch
        guard iOSSamplingManager.shared.isTrackingEnabled else { return }
        release(tag: tag)
    }

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
        var additionalHeld:    Double = 0
        var additionalBg:      Double = 0
        var longestActiveHeld: Double = 0   // ✅ track in-progress max for top-level
        var currentlyActive   = 0

        for info in activeWakeLocks.values {
            let held = now - info.acquireTimeMs
            additionalHeld    += held
            currentlyActive   += 1
            if held > longestActiveHeld { longestActiveHeld = held }
            if let bgStart = info.bgStartTimeMs { additionalBg += now - bgStart }
        }

        // ✅ Issue 3 fix: the top-level maxMs must include any currently-active
        //    hold that's already exceeded the longest completed hold.
        let effectiveTopLevelMax = max(maxSingleHeldMs, longestActiveHeld)

        var result: [String: Any] = [
            "totalMs":       Int(totalHeldTimeMs + additionalHeld),
            "count":         totalAcquireCount,
            "bgMs":          Int(totalBgTimeMs + additionalBg),
            "maxMs":         Int(effectiveTopLevelMax),
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

                // ✅ Issue 3 fix: per-lock maxMs must consider the currently-active
                //    hold's running duration. Without this, a lock that's been held
                //    for 5 seconds (and never released) reports maxMs: 0 because
                //    metrics.maxHeldMs is only updated in release().
                let effectiveMax = isActive
                    ? max(metrics.maxHeldMs, extraHeld)
                    : metrics.maxHeldMs

                var lockDict: [String: Any] = [
                    "tag":     metrics.tag,
                    "cnt":     metrics.acquireCount,
                    "totalMs": Int(metrics.totalHeldMs + extraHeld),
                    "maxMs":   Int(effectiveMax),
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

    /// Monotonic milliseconds. Every value derived from this is an elapsed
    /// duration — no absolute timestamp leaves this file — so the uptime clock
    /// is the correct source. `Date()` is not monotonic: an NTP correction or
    /// a user changing the device clock mid-hold produced a nonsense duration,
    /// and a backwards step produced a negative one that then propagated into
    /// totalMs and maxMs.
    private func nowMs() -> Double {
        return ProcessInfo.processInfo.systemUptime * 1000.0
    }
}