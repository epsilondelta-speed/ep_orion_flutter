import Foundation

/// OrionCrashStore — reliable delivery for iOS crash beacons.
///
/// PROBLEM THIS SOLVES
///   The previous implementation sent the crash beacon from inside
///   NSSetUncaughtExceptionHandler via SendData().coronaGo(...), which
///   hands off to DispatchQueue.global().async and then URLSession
///   task.resume() — two asynchronous hops. iOS tears the process down
///   almost immediately after an uncaught exception, so the POST usually
///   never completed. A Thread.sleep(0.5) was used to hold the process
///   open and hope; that is a race the SDK frequently lost, which is why
///   iOS crashes appeared in Crashlytics but not in Orion.
///
/// APPROACH — NEXT-LAUNCH DELIVERY
///   The crash handler now does exactly one thing: serialize the beacon
///   and write it to disk (synchronous, completes before the process
///   dies). On the NEXT launch, flushPendingCrash() reads the file, sends
///   the beacon normally, and deletes the file. Delivery becomes
///   deterministic instead of a race.
///
/// SCOPE (deliberate, 1.2.27)
///   This handles Objective-C exceptions only — the same crashes the
///   existing NSSetUncaughtExceptionHandler already caught. Low-level
///   memory faults (EXC_BAD_ACCESS / KERN_INVALID_ADDRESS) are delivered
///   as POSIX signals and require sigaction-based handlers, which are NOT
///   part of this change. Those are planned for a later release after
///   dedicated validation (signal handlers must be async-signal-safe and
///   must chain correctly with Crashlytics/Sentry).
///
/// SAFETY
///   No signal handlers, no async-signal-safety constraints, no changes to
///   handler chaining. The only behavioral change inside the crash handler
///   is "write to disk" instead of "async POST + sleep". Everything else in
///   the crash path is untouched.
enum OrionCrashStore {

    /// Marker prefix so a truncated/corrupt file is detected rather than
    /// parsed into a malformed beacon.
    private static let marker = "ORION_CRASH_V1\n"

    private static var pendingCrashPath: String {
        let dir = NSSearchPathForDirectoriesInDomains(.libraryDirectory,
                                                      .userDomainMask, true).first
                  ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("orion_pending_crash.json")
    }

    // MARK: - Called from the crash handler (crash time)

    /// Serialize and write the crash beacon to disk synchronously.
    ///
    /// Must be fast and must not depend on the network or on any async
    /// work — the process is about to die. Everything here is normal
    /// (non-signal) context because it is invoked from an Objective-C
    /// exception handler, so JSONSerialization is safe to use.
    static func persist(_ beacon: [String: Any]) {
        do {
            let json = try JSONSerialization.data(withJSONObject: beacon, options: [])
            guard var out = marker.data(using: .utf8) else { return }
            out.append(json)
            // .atomic ensures we never leave a half-written file behind if
            // the process dies mid-write.
            try out.write(to: URL(fileURLWithPath: pendingCrashPath), options: .atomic)
            NSLog("[Orion] CRASH-DIAG persisted \(out.count) bytes to \(pendingCrashPath)")
        } catch {
            // DIAGNOSTIC (1.2.28): this catch previously swallowed silently,
            // so a JSON-serialization or write failure was indistinguishable
            // from the handler never running. Unconditional NSLog because
            // OrionLogger produces nothing in release builds.
            NSLog("[Orion] CRASH-DIAG persist FAILED: \(error)")
            // Still never rethrow — the app is terminating either way.
        }
    }

    // MARK: - Called at app launch

    /// Read, send, and delete a crash persisted by the PREVIOUS launch.
    ///
    /// Call once during plugin init, AFTER iOSSamplingManager.initialize()
    /// (the crash sampling gate is applied here, at send time, using the
    /// current config) and AFTER SendData.startNetworkMonitor().
    ///
    /// The file is deleted regardless of whether the send succeeds, so a
    /// crash is never re-sent on a subsequent launch. A single crash report
    /// is worth less than an unbounded retry loop that could duplicate
    /// beacons for every launch thereafter.
    static func flushPendingCrash() {
        let path = pendingCrashPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        // Delete on every exit path from this function.
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard let raw = FileManager.default.contents(atPath: path) else {
            OrionLogger.warn("OrionCrashStore: pending crash file unreadable — dropped")
            return
        }

        guard let markerData = marker.data(using: .utf8),
              raw.count > markerData.count,
              raw.prefix(markerData.count) == markerData else {
            OrionLogger.warn("OrionCrashStore: pending crash file corrupt — dropped")
            return
        }

        let jsonData = raw.dropFirst(markerData.count)
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData),
              var beacon = obj as? [String: Any] else {
            OrionLogger.warn("OrionCrashStore: pending crash JSON invalid — dropped")
            return
        }

        // Mark that this beacon was delivered on a later launch than the
        // crash. Useful on the backend: sesId belongs to the CURRENT
        // session, not the crashed one (the crashed session's id is not
        // recoverable after the process died).
        beacon["crashDeliveredOnNextLaunch"] = true

        OrionLogger.debug("OrionCrashStore: delivering pending crash from previous launch "
                          + "(\(beacon["crashType"] as? String ?? "unknown"))")

        // beaconType == "crash" → SendData applies the lenient
        // shouldSendCrashAnr() gate (kill switch still honored).
        SendData().coronaGo(beacon)
    }
}