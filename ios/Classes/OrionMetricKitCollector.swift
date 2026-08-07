import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// OrionMetricKitCollector (1.2.29) — OS-level diagnostics via MetricKit.
///
/// WHAT THIS ADDS
///   MetricKit is Apple's own diagnostic pipeline. The OS collects the data
///   and hands it over in a batch; the SDK does no sampling, polling, or
///   thread manipulation of its own. It fills three gaps at once:
///
///     • Hang stacks         — MXHangDiagnostic carries the main-thread call
///                             stack, so a hang report can say which binary
///                             the thread was stuck in, not just which screen.
///     • Watchdog kills      — MXCrashDiagnostic includes 0x8badf00d
///                             terminations. This is the genuine iOS analogue
///                             of an Android ANR, and there is no other way to
///                             detect it: at kill time the process is being
///                             destroyed and cannot run code.
///     • Signal-class crashes— EXC_BAD_ACCESS and friends appear here without
///                             the SDK installing any signal handlers.
///
/// RUNTIME COST: ESSENTIALLY ZERO
///   No timers, no polling, no thread suspension, no locks on any hot path.
///   The OS performs collection out-of-process. This class only wakes when a
///   payload is delivered — at most a handful of times per day — and all of
///   that work happens on a private serial background queue at utility QoS.
///   The main thread is never touched.
///
/// DELIVERY IS NOT REAL-TIME
///   iOS batches diagnostics and delivers them roughly once every 24 hours,
///   at app launch, covering the *previous* period. Beacons therefore
///   describe historical events: each carries the diagnostic's own timestamp,
///   and the enclosing session id belongs to the launch that *delivered* it,
///   not the one where it happened. Backends must key on `ts`, not arrival.
///
/// STACKS ARE NOT SYMBOLICATED
///   MetricKit reports frames as binaryName + offsetIntoBinaryTextSegment +
///   binaryUUID (e.g. "Runner +0x1a2f4c"). Turning that into a function and
///   line number requires the matching dSYM, server-side. Unsymbolicated
///   frames still identify which binary was executing — app code vs UIKit vs
///   a third-party SDK — which is often enough to route an investigation.
///
/// AVAILABILITY: iOS 14+. On earlier versions every entry point is a no-op.
@objc final class OrionMetricKitCollector: NSObject {

    // MARK: - Singleton

    @objc static let shared = OrionMetricKitCollector()
    private override init() { super.init() }

    // MARK: - Tunables

    /// Frames kept per stack. MetricKit call-stack trees can run to tens of
    /// kilobytes; the top frames carry nearly all the diagnostic value, and
    /// trimming keeps beacons small enough to stay within normal payload
    /// budgets.
    private let maxFrames = 20

    /// Upper bound on diagnostics read from a single payload before grouping.
    private let maxDiagnosticsPerPayload = 50

    /// Distinct signature groups emitted per beacon. Beyond this the least
    /// severe / least frequent groups are dropped and `groupsTruncated` is set.
    /// 8 groups x 20 frames keeps the beacon around 6 KB worst case, in line
    /// with a normal screen beacon.
    private let maxGroups = 8

    /// Frames used to build a group's signature. Deeper than this and
    /// genuinely-identical hangs stop grouping because of minor tail
    /// differences; shallower and unrelated issues merge.
    private let fingerprintDepth = 5

    /// Hang severity thresholds (ms).
    private let severeHangMs   = 2000
    private let criticalHangMs = 5000

    /// Marks the newest payload timestamp already processed, so a redelivered
    /// payload cannot produce duplicate beacons.
    private let lastProcessedKey = "orion_mx_last_processed"

    // MARK: - State

    /// Private serial queue — all parsing and beacon assembly happens here.
    /// Serial so two payloads can never be processed concurrently, utility QoS
    /// so it never competes with UI work.
    private let queue = DispatchQueue(label: "co.epsilondelta.orion.metrickit",
                                      qos: .utility)

    private var subscribed = false

    // MARK: - Public API

    /// Subscribe to MetricKit. Idempotent; safe to call on every init.
    /// No-op below iOS 14.
    @objc func start() {
        #if canImport(MetricKit)
        guard #available(iOS 14.0, *) else {
            OrionLogger.debug("MetricKit: unavailable (requires iOS 14+)")
            return
        }
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
        OrionLogger.debug("MetricKit: subscribed")
        #endif
    }

    @objc func stop() {
        #if canImport(MetricKit)
        guard #available(iOS 14.0, *), subscribed else { return }
        MXMetricManager.shared.remove(self)
        subscribed = false
        #endif
    }
}

// MARK: - MXMetricManagerSubscriber

#if canImport(MetricKit)
@available(iOS 14.0, *)
extension OrionMetricKitCollector: MXMetricManagerSubscriber {

    /// Performance metrics payload — not consumed. The SDK already collects
    /// its own session-scoped performance data; MetricKit's aggregate daily
    /// metrics would duplicate it without adding per-session context.
    func didReceive(_ payloads: [MXMetricPayload]) { }

    /// Diagnostic payload — hangs, crashes, watchdog kills, CPU and disk
    /// exceptions. This callback is delivered by the system off the main
    /// thread; work is moved to our own serial queue regardless so ordering
    /// is deterministic and nothing blocks the caller.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for payload in payloads {
                self.process(payload)
            }
        }
    }

    // MARK: - Payload processing (background queue only)

    private func process(_ payload: MXDiagnosticPayload) {
        // Skip payloads already handled — MetricKit can redeliver.
        let stamp = payload.timeStampEnd.timeIntervalSince1970
        let last  = UserDefaults.standard.double(forKey: lastProcessedKey)
        guard stamp > last else {
            OrionLogger.debug("MetricKit: payload already processed, skipping")
            return
        }
        UserDefaults.standard.set(stamp, forKey: lastProcessedKey)

        // ── 1. Collect raw diagnostics ───────────────────────────────────
        var items: [DiagItem] = []

        for d in payload.hangDiagnostics ?? [] {
            guard items.count < maxDiagnosticsPerPayload else { break }
            let ms = Int(d.hangDuration.converted(to: .milliseconds).value)
            items.append(DiagItem(
                diagType: "hang",
                category: hangCategory(ms),
                durationMs: ms,
                stack: Self.flatten(d.callStackTree, limit: maxFrames) ?? [],
                extra: [:]
            ))
        }

        for d in payload.crashDiagnostics ?? [] {
            guard items.count < maxDiagnosticsPerPayload else { break }
            let isWatchdog = Self.isWatchdogTermination(d)
            var extra: [String: Any] = [:]
            if let reason = d.terminationReason { extra["terminationReason"] = reason }
            if let sig    = d.signal            { extra["signal"]            = sig.intValue }
            if let et     = d.exceptionType     { extra["exceptionType"]     = et.intValue }
            if let ec     = d.exceptionCode     { extra["exceptionCode"]     = ec.intValue }
            items.append(DiagItem(
                diagType: isWatchdog ? "watchdog" : "crash",
                category: "critical",
                durationMs: 0,
                stack: Self.flatten(d.callStackTree, limit: maxFrames) ?? [],
                extra: extra
            ))
        }

        for d in payload.cpuExceptionDiagnostics ?? [] {
            guard items.count < maxDiagnosticsPerPayload else { break }
            items.append(DiagItem(
                diagType: "cpuException",
                category: "severe",
                durationMs: Int(d.totalCPUTime.converted(to: .milliseconds).value),
                stack: Self.flatten(d.callStackTree, limit: maxFrames) ?? [],
                extra: [:]
            ))
        }

        for d in payload.diskWriteExceptionDiagnostics ?? [] {
            guard items.count < maxDiagnosticsPerPayload else { break }
            items.append(DiagItem(
                diagType: "diskWriteException",
                category: "mild",
                durationMs: 0,
                stack: Self.flatten(d.callStackTree, limit: maxFrames) ?? [],
                extra: ["bytesWritten": Int(d.totalWritesCaused.converted(to: .bytes).value)]
            ))
        }

        guard !items.isEmpty else { return }

        // ── 2. Group by signature and emit ONE beacon ────────────────────
        let groups = group(items)
        send(buildBeacon(groups: groups, totalItems: items.count, payload: payload))

        OrionLogger.debug("MetricKit: \(items.count) diagnostic(s) -> \(groups.count) group(s), 1 beacon")
    }

    // MARK: - Grouping

    /// One raw diagnostic before grouping.
    private struct DiagItem {
        let diagType:   String
        let category:   String
        let durationMs: Int
        let stack:      [String]
        let extra:      [String: Any]
    }

    /// A set of diagnostics sharing a signature, reported once with a count.
    private struct DiagGroup {
        let fingerprint: String
        let diagType:    String
        var category:    String
        var count:       Int
        var worstMs:     Int
        var totalMs:     Int
        let stack:       [String]
        let extra:       [String: Any]
    }

    /// Collapse diagnostics that share a signature.
    ///
    /// Same idea as the server-side crash fingerprinting: identical stacks are
    /// the same underlying bug, so shipping twenty copies of one stack wastes
    /// payload without adding information. One representative stack plus a
    /// count carries the same meaning.
    private func group(_ items: [DiagItem]) -> [DiagGroup] {
        var byFp: [String: DiagGroup] = [:]

        for item in items {
            let fp = Self.fingerprint(diagType: item.diagType,
                                      stack: item.stack,
                                      depth: fingerprintDepth)
            if var g = byFp[fp] {
                g.count   += 1
                g.worstMs  = max(g.worstMs, item.durationMs)
                g.totalMs += item.durationMs
                // A group takes the severity of its worst member.
                if Self.severityRank(item.category) > Self.severityRank(g.category) {
                    g.category = item.category
                }
                byFp[fp] = g
            } else {
                byFp[fp] = DiagGroup(
                    fingerprint: fp,
                    diagType:    item.diagType,
                    category:    item.category,
                    count:       1,
                    worstMs:     item.durationMs,
                    totalMs:     item.durationMs,
                    stack:       item.stack,
                    extra:       item.extra
                )
            }
        }

        // Most severe first, then most frequent — so truncation drops the
        // least interesting groups.
        return byFp.values.sorted {
            let a = Self.severityRank($0.category), b = Self.severityRank($1.category)
            return a != b ? a > b : $0.count > $1.count
        }
    }

    private static func severityRank(_ category: String) -> Int {
        switch category {
        case "critical": return 3
        case "severe":   return 2
        case "mild":     return 1
        default:         return 0
        }
    }

    /// Deterministic signature from diagType + the top frames.
    ///
    /// FNV-1a rather than Swift's `hashValue`, which is seeded per-process and
    /// would produce a different fingerprint on every launch — useless for
    /// grouping across sessions or devices.
    static func fingerprint(diagType: String, stack: [String], depth: Int) -> String {
        var input = diagType
        for frame in stack.prefix(depth) { input += "|" + frame }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Beacon assembly

    private func buildBeacon(groups: [DiagGroup],
                             totalItems: Int,
                             payload: MXDiagnosticPayload) -> [String: Any] {
        let kept = Array(groups.prefix(maxGroups))

        var beacon: [String: Any] = [
            "beaconType": "appIosdiagnostic",
            "flutter":    1,
            "source":     "metrickit",

            // Routing — appendCommonFields does not supply these, and the
            // aggregation reads cid/pid from the document body.
            "cid": OrionConfig.companyId,
            "pid": OrionConfig.projectId,

            // The diagnostic window. The enclosing session belongs to the
            // launch that DELIVERED this, not the one that produced it, so
            // backends must key on `ts`, never on arrival time.
            "ts":          Int64(payload.timeStampEnd.timeIntervalSince1970 * 1000),
            "windowStart": Int64(payload.timeStampBegin.timeIntervalSince1970 * 1000),
            "deliveredOnLaterLaunch": true,

            "diagCount":  totalItems,
            "groupCount": kept.count
        ]

        if kept.count < groups.count {
            beacon["groupsTruncated"] = true
            beacon["groupsDropped"]   = groups.count - kept.count
        }

        // App/OS version AT THE TIME of the diagnostic — may differ from the
        // current build if the user updated in between.
        let meta = payload.metaData
        beacon["diagAppVer"] = meta.applicationBuildVersion
        beacon["diagOsVer"]  = meta.osVersion
        beacon["diagDevice"] = meta.deviceType

        beacon["diagnostics"] = kept.map { g -> [String: Any] in
            var d: [String: Any] = [
                "fp":       g.fingerprint,
                "diagType": g.diagType,
                "category": g.category,
                "count":    g.count
            ]
            if g.worstMs > 0 { d["worstMs"] = g.worstMs }
            if g.totalMs > 0 { d["totalMs"] = g.totalMs }
            if !g.stack.isEmpty {
                d["stack"]          = g.stack
                d["stackFrames"]    = g.stack.count
                d["stackTruncated"] = g.stack.count >= maxFrames
                // Frames are binaryName + offset; symbolication needs the
                // dSYM and happens server-side.
                d["stackSymbolicated"] = false
            }
            for (k, v) in g.extra { d[k] = v }
            return d
        }

        return beacon
    }

    private func hangCategory(_ ms: Int) -> String {
        if ms >= criticalHangMs { return "critical" }
        if ms >= severeHangMs   { return "severe" }
        return "mild"
    }


    // MARK: - Call-stack tree flattening

    /// Convert an MXCallStackTree into an ordered list of
    /// "binaryName +0xOFFSET" strings, outermost frame first.
    ///
    /// MetricKit models a stack as a tree (`subFrames`) because a payload can
    /// aggregate several samples. For a single diagnostic there is normally
    /// one dominant path, so we follow the highest-sampled child at each level
    /// to recover a linear stack.
    ///
    /// Returns nil when the tree cannot be parsed — never throws. A diagnostic
    /// without a stack is still worth reporting.
    static func flatten(_ tree: MXCallStackTree, limit: Int) -> [String]? {
        let data = tree.jsonRepresentation()
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data))
                          as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]]
        else { return nil }

        // Prefer the thread MetricKit attributed the problem to.
        let chosen = stacks.first { ($0["threadAttributed"] as? Bool) == true }
                     ?? stacks.first
        guard let rootFrames = chosen?["callStackRootFrames"] as? [[String: Any]]
        else { return nil }

        var out: [String] = []
        var level = rootFrames

        while !level.isEmpty && out.count < limit {
            guard let frame = level.max(by: {
                (($0["sampleCount"] as? Int) ?? 0) < (($1["sampleCount"] as? Int) ?? 0)
            }) else { break }

            let name   = (frame["binaryName"] as? String) ?? "<unknown>"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            out.append("\(name) +0x" + String(offset, radix: 16))

            level = (frame["subFrames"] as? [[String: Any]]) ?? []
        }

        return out
    }

    // MARK: - Watchdog detection

    /// A watchdog termination is the OS killing the app for being
    /// unresponsive — exception code 0x8badf00d ("ate bad food"). This is the
    /// genuine iOS analogue of an Android ANR, and MetricKit is the only way
    /// to observe it: at kill time the process is being destroyed and cannot
    /// run any code of its own.
    static func isWatchdogTermination(_ d: MXCrashDiagnostic) -> Bool {
        if let code = d.exceptionCode?.intValue, code == 0x8badf00d {
            return true
        }
        if let reason = d.terminationReason?.lowercased(),
           reason.contains("8badf00d") || reason.contains("watchdog") {
            return true
        }
        return false
    }

    // MARK: - Send

    /// Diagnostics bypass the sampling dice-roll.
    ///
    /// One grouped beacon per device per day is negligible bandwidth, and
    /// sampling something that rare would make the dataset statistically
    /// useless. `coronaGoForced` still honours the runtime kill switch, so
    /// `disable()` continues to suppress it.
    private func send(_ beacon: [String: Any]) {
        SendData().coronaGoForced(beacon)
    }
}
#endif
