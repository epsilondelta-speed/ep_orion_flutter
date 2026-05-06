import Foundation

/// iOSSamplingManager — Native-side sampling gate for iOS, V2 schema.
/// Mirrors SamplingManager.kt (Android) and SamplingManager.dart.
///
/// V2 changes from prior versions of this file:
///
/// 1. CDN URL bumped from confOriSampl.json to confOriSamplV2.json.
///
/// 2. Schema migration. Per-field resolution now follows:
///        c[cid].p[pid].FIELD → c[cid].FIELD → FIELD → default
///    where FIELD is one of:
///        s    (Int 0–100, default 100) — sampling percent
///        sa   (Bool, default false)    — when false, analytics URLs filtered
///        crm  (Int minutes, default 15) — config refresh interval
///        cv   (String, default "1.0", GLOBAL ONLY) — config version
///    Per-PID is now an object containing any of {s, sa, crm}, not a bare Int.
///
/// 3. New API surface to support callers that need each field individually:
///        getEffectivePercent()      — sampling %
///        shouldFilterAnalytics()    — true when sa=false (filter is on)
///        getConfigRefreshMin()      — refresh minutes
///        getConfigVersion()         — version string
///        getConfigSnapshot()        — atomic [s, sa, crm, cv] for cf injection
///
/// 4. shouldSendCrashAnr() — lenient policy for crash beacons:
///        s == 0  → false (kill switch)
///        s > 10  → true  (always send)
///        s ≤ 10  → roll dice at s%
///    Crashes are too valuable to lose at low sample rates. Mirror of
///    SamplingManager.kt.
///
/// 5. crm now drives the refresh timer. After the first successful fetch,
///    if crm differs from the current interval, the timer is restarted.
///
/// Carryover from the previous file:
///
/// * Timer is DispatchSourceTimer (no RunLoop dependency, fires reliably
///   from any calling thread).
/// * isTrackingEnabled returns false when effective percent == 0.
final class iOSSamplingManager {

    // MARK: - Singleton
    static let shared = iOSSamplingManager()
    private init() {}

    // MARK: - Constants
    private let cdnURL          = "https://cdn.epsilondelta.co/orion/confOriSamplV2.json"
    private let fetchTimeout:   TimeInterval = 10

    // V2 field defaults — mirror SamplingManager.kt.
    private let defaultPercent:      Int    = 100
    private let defaultFilterRawSa:  Bool   = false   // sa=false ⇒ filter ON
    private let defaultRefreshMin:   Int    = 15
    private let defaultConfigVer:    String = "1.0"

    // MARK: - State (guarded by lock)
    private var cid:             String = ""
    private var pid:             String = ""
    private var localRate:       Int    = 100
    private var firstBeaconSent: Bool   = false
    private var configLoaded:    Bool   = false

    // Last-resolved snapshot. nil until first successful fetch.
    private var resolvedPercent:    Int?    = nil
    private var resolvedRawSa:      Bool?   = nil
    private var resolvedRefreshMin: Int?    = nil
    private var resolvedConfigVer:  String? = nil

    private let lock = NSLock()
    private var refreshTimer: DispatchSourceTimer?
    private var currentTimerIntervalMin: Int = 15  // tracked so we know when to restart

    // MARK: - Init

    func initialize(cid: String, pid: String, localRatePercent: Int = 100) {
        lock.lock()
        self.cid             = cid
        self.pid             = pid
        self.localRate       = localRatePercent.clamped(to: 0...100)
        self.firstBeaconSent = false
        self.configLoaded    = false
        self.resolvedPercent    = nil
        self.resolvedRawSa      = nil
        self.resolvedRefreshMin = nil
        self.resolvedConfigVer  = nil
        lock.unlock()

        fetchConfig()
        startRefreshTimer(intervalMin: defaultRefreshMin)

        OrionLogger.debug("iOSSamplingManager: initialized cid=\(cid) pid=\(pid) localRate=\(localRatePercent)%")
    }

    // MARK: - Beacon-send gates

    /// Whether telemetry collection should run.
    /// Returns false ONLY when effective percent == 0 (kill switch).
    /// Used at collection sites to skip work entirely.
    /// Crash beacons must NEVER consult this — they have their own gate below.
    var isTrackingEnabled: Bool {
        return getEffectivePercent() > 0
    }

    /// Regular per-beacon gate. Mirrors shouldSendSample in Kotlin/Dart.
    func shouldSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !firstBeaconSent {
            firstBeaconSent = true
            OrionLogger.debug("iOSSamplingManager: first beacon — always send")
            return true
        }

        let percent = resolvedPercent ?? localRate
        if percent >= 100 { return true }
        if percent <= 0 {
            OrionLogger.debug("iOSSamplingManager: beacon dropped (0%)")
            return false
        }

        let roll = Int.random(in: 1...100)
        let send = roll <= percent
        OrionLogger.debug("iOSSamplingManager: roll=\(roll) percent=\(percent) → \(send ? "SEND" : "DROP")")
        return send
    }

    /// Lenient gate for crash and ANR beacons.
    /// Crash signal is too valuable to lose probabilistically at low sample
    /// rates, so above 10% we always send. Below 10% we roll. At 0 we honor
    /// the kill switch.
    func shouldSendCrashAnr() -> Bool {
        let percent = getEffectivePercent()
        if percent == 0 {
            OrionLogger.debug("iOSSamplingManager: crash dropped (kill switch)")
            return false
        }
        if percent > 10 {
            return true
        }
        let roll = Int.random(in: 1...100)
        let send = roll <= percent
        OrionLogger.debug("iOSSamplingManager: crash roll=\(roll) percent=\(percent) → \(send ? "SEND" : "DROP")")
        return send
    }

    // MARK: - V2 field accessors

    func getEffectivePercent() -> Int {
        lock.lock(); defer { lock.unlock() }
        return resolvedPercent ?? localRate
    }

    /// True when the analytics URL filter is ON (i.e. raw `sa` is false).
    /// Callers that want to filter should check `if shouldFilterAnalytics() { skip }`.
    func shouldFilterAnalytics() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let rawSa = resolvedRawSa ?? defaultFilterRawSa
        return !rawSa
    }

    func getConfigRefreshMin() -> Int {
        lock.lock(); defer { lock.unlock() }
        return resolvedRefreshMin ?? defaultRefreshMin
    }

    func getConfigVersion() -> String {
        lock.lock(); defer { lock.unlock() }
        return resolvedConfigVer ?? defaultConfigVer
    }

    /// Atomic snapshot of the four V2 fields, suitable for embedding as the
    /// `cf` field on outgoing beacons. Read under the lock so all four values
    /// come from the same config evaluation — no torn reads if a refresh is
    /// happening concurrently.
    func getConfigSnapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "s":   resolvedPercent    ?? localRate,
            "sa":  resolvedRawSa      ?? defaultFilterRawSa,
            "crm": resolvedRefreshMin ?? defaultRefreshMin,
            "cv":  resolvedConfigVer  ?? defaultConfigVer
        ]
    }

    var isConfigLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return configLoaded
    }

    func shutdown() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Refresh timer

    private func startRefreshTimer(intervalMin: Int) {
        refreshTimer?.cancel()
        let interval = TimeInterval(max(1, intervalMin) * 60)
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline:  .now() + interval,
            repeating: interval,
            leeway:    .seconds(60)
        )
        timer.setEventHandler { [weak self] in self?.fetchConfig() }
        timer.resume()
        refreshTimer = timer
        currentTimerIntervalMin = intervalMin
    }

    // MARK: - CDN Fetch

    private func fetchConfig() {
        guard let url = URL(string: cdnURL) else { return }

        var request = URLRequest(url: url)
        request.cachePolicy     = .reloadIgnoringLocalCacheData
        request.timeoutInterval = fetchTimeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                OrionLogger.debug("iOSSamplingManager: CDN error — \(error.localizedDescription)")
                return
            }
            guard
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                OrionLogger.debug("iOSSamplingManager: CDN bad response — using fallback")
                return
            }

            // Resolve all four fields from the same JSON object.
            let s   = self.resolveInt(json,    field: "s",   default: self.defaultPercent).clamped(to: 0...100)
            let sa  = self.resolveBool(json,   field: "sa",  default: self.defaultFilterRawSa)
            let crm = self.resolveInt(json,    field: "crm", default: self.defaultRefreshMin)
            let cv  = self.resolveStringGlobal(json, field: "cv", default: self.defaultConfigVer)

            self.lock.lock()
            self.resolvedPercent    = s
            self.resolvedRawSa      = sa
            self.resolvedRefreshMin = crm
            self.resolvedConfigVer  = cv
            self.configLoaded       = true
            let needsTimerRestart   = (crm != self.currentTimerIntervalMin)
            self.lock.unlock()

            OrionLogger.debug("iOSSamplingManager: config loaded — s=\(s) sa=\(sa) crm=\(crm) cv=\(cv)")

            // Restart timer if crm changed. Done outside the lock; DispatchSourceTimer
            // cancel/recreate is safe to call from any queue.
            if needsTimerRestart {
                OrionLogger.debug("iOSSamplingManager: restarting refresh timer (\(self.currentTimerIntervalMin)→\(crm) min)")
                self.startRefreshTimer(intervalMin: crm)
            }
        }.resume()
    }

    // MARK: - V2 Resolution helpers
    //
    // Priority chain per FIELD: c[cid].p[pid].FIELD → c[cid].FIELD → FIELD → default.
    // `cv` is the exception — it's GLOBAL ONLY, no per-cid/pid override.

    private func resolveInt(_ config: [String: Any], field: String, default fallback: Int) -> Int {
        // c[cid].p[pid].field
        if !cid.isEmpty,
           let cidEntry = (config["c"] as? [String: Any])?[cid] as? [String: Any] {
            if !pid.isEmpty,
               let pidEntry = (cidEntry["p"] as? [String: Any])?[pid] as? [String: Any],
               let v = toInt(pidEntry[field]) {
                return v
            }
            // c[cid].field
            if let v = toInt(cidEntry[field]) {
                return v
            }
        }
        // global field
        if let v = toInt(config[field]) {
            return v
        }
        return fallback
    }

    private func resolveBool(_ config: [String: Any], field: String, default fallback: Bool) -> Bool {
        if !cid.isEmpty,
           let cidEntry = (config["c"] as? [String: Any])?[cid] as? [String: Any] {
            if !pid.isEmpty,
               let pidEntry = (cidEntry["p"] as? [String: Any])?[pid] as? [String: Any],
               let v = toBool(pidEntry[field]) {
                return v
            }
            if let v = toBool(cidEntry[field]) {
                return v
            }
        }
        if let v = toBool(config[field]) {
            return v
        }
        return fallback
    }

    /// Global-only resolution (used for `cv`). Per-cid and per-pid overrides
    /// are ignored deliberately to match SamplingManager.kt.
    private func resolveStringGlobal(_ config: [String: Any], field: String, default fallback: String) -> String {
        if let s = config[field] as? String, !s.isEmpty {
            return s
        }
        return fallback
    }

    // MARK: - JSON value coercion
    //
    // CDN config can have ints written as 50, 50.0, or "50" depending on
    // who edited the file. Kotlin/Dart sides accept all three; mirror that here.

    private func toInt(_ value: Any?) -> Int? {
        if let i = value as? Int       { return i }
        if let n = value as? NSNumber  { return n.intValue }
        if let d = value as? Double    { return Int(d) }
        if let s = value as? String    { return Int(s) }
        return nil
    }

    private func toBool(_ value: Any?) -> Bool? {
        // JSONSerialization wraps `true`/`false` as __NSCFBoolean which
        // bridges cleanly to Bool. Numeric 1/0 wrapped as NSNumber don't
        // match `as? Bool` (which is what we want — we shouldn't treat 1/0
        // as bool). String "true"/"false" handled for editor leniency.
        if let b = value as? Bool   { return b }
        if let s = value as? String {
            switch s.lowercased() {
            case "true":  return true
            case "false": return false
            default:      return nil
            }
        }
        return nil
    }
}

// MARK: - Comparable clamp helper
// Defined here once for the SDK. If another file already declares this
// extension, delete this block to avoid a duplicate-symbol compile error.
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}