import Foundation

/// iOSSamplingManager — Native-side sampling gate for iOS.
/// Mirrors SamplingManager.kt (Android) and SamplingManager.dart.
///
/// Fixes applied:
///
/// 1. Timer replaced with DispatchSourceTimer.
///    Timer.scheduledTimer() must be scheduled on a RunLoop.  If initialize()
///    is called from a background thread (e.g. from the Flutter method channel
///    before the first foreground event) the timer is silently never fired
///    because background thread RunLoops are not running.
///    DispatchSourceTimer runs on a DispatchQueue and has no RunLoop dependency.
///
/// 2. isTrackingEnabled — mirrors Android SamplingManager.isTrackingEnabled().
///    Returns false when effectivePercent == 0 (kill-switch active).
///    Collection sites (MemoryMetricsTracker, WakeLockTracker) check this to
///    skip data gathering entirely when the kill-switch is active, saving CPU.
///
/// 3. Comparable.clamped extension removed from this file — it lives in a
///    dedicated Extensions file (see below) to avoid duplicate-symbol errors if
///    any other SDK file also defines it.
final class iOSSamplingManager {

    // MARK: - Singleton
    static let shared = iOSSamplingManager()
    private init() {}

    // MARK: - Constants
    private let cdnURL          = "https://cdn.epsilondelta.co/orion/confOriSampl.json"
    private let refreshInterval: TimeInterval = 15 * 60
    private let fetchTimeout:    TimeInterval = 10

    // MARK: - State (guarded by lock)
    private var cid:             String = ""
    private var pid:             String = ""
    private var localRate:       Int    = 100
    private var remotePercent:   Int?   = nil
    private var firstBeaconSent: Bool   = false
    private var configLoaded:    Bool   = false
    private let lock = NSLock()

    // ✅ DispatchSourceTimer — fires reliably from any calling thread.
    private var refreshTimer: DispatchSourceTimer?

    // MARK: - Init

    func initialize(cid: String, pid: String, localRatePercent: Int = 100) {
        lock.lock()
        self.cid             = cid
        self.pid             = pid
        self.localRate       = localRatePercent.clamped(to: 0...100)
        self.firstBeaconSent = false
        self.configLoaded    = false
        self.remotePercent   = nil
        lock.unlock()

        fetchConfig()

        // ✅ DispatchSourceTimer — no RunLoop dependency.
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + refreshInterval,
            repeating: refreshInterval,
            leeway:    .seconds(60)
        )
        timer.setEventHandler { [weak self] in self?.fetchConfig() }
        timer.resume()
        refreshTimer = timer

        OrionLogger.debug("iOSSamplingManager: initialized cid=\(cid) pid=\(pid) localRate=\(localRatePercent)%")
    }

    // MARK: - Collection-site gate

    /// Whether telemetry *collection* should run.
    ///
    /// Returns false ONLY when effectivePercent == 0 (kill-switch active).
    /// Use at collection sites: MemoryMetricsTracker.onScreenTransition(),
    /// WakeLockTracker.trackAcquire/trackRelease().
    ///
    /// Crash/error beacons must NEVER check this — they always collect and send.
    var isTrackingEnabled: Bool {
        return getEffectivePercent() > 0
    }

    // MARK: - Beacon-send gate (mirrors shouldSendSample in Kotlin/Dart)

    func shouldSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !firstBeaconSent {
            firstBeaconSent = true
            OrionLogger.debug("iOSSamplingManager: first beacon — always send")
            return true
        }

        let percent = remotePercent ?? localRate
        if percent >= 100 { return true }
        if percent <= 0   {
            OrionLogger.debug("iOSSamplingManager: beacon dropped (0%)")
            return false
        }

        let roll = Int.random(in: 1...100)
        let send = roll <= percent
        OrionLogger.debug("iOSSamplingManager: roll=\(roll) percent=\(percent) → \(send ? "SEND" : "DROP")")
        return send
    }

    func getEffectivePercent() -> Int {
        lock.lock(); defer { lock.unlock() }
        return remotePercent ?? localRate
    }

    var isConfigLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return configLoaded
    }

    func shutdown() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - CDN Fetch

    private func fetchConfig() {
        guard let url = URL(string: cdnURL) else { return }

        var request = URLRequest(url: url)
        request.cachePolicy    = .reloadIgnoringLocalCacheData
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

            let resolved = self.resolvePercent(json)
            self.lock.lock()
            self.remotePercent = resolved
            self.configLoaded  = true
            self.lock.unlock()

            OrionLogger.debug("iOSSamplingManager: config loaded — effective=\(resolved)%")
        }.resume()
    }

    // MARK: - Resolution (mirrors Dart _resolvePercent exactly)

    private func resolvePercent(_ config: [String: Any]) -> Int {
        if !cid.isEmpty,
           let cidEntry = (config["c"] as? [String: Any])?[cid] as? [String: Any] {

            if !pid.isEmpty,
               let pidVal = (cidEntry["p"] as? [String: Any])?[pid] as? Int {
                OrionLogger.debug("iOSSamplingManager: resolved c[\(cid)].p[\(pid)] = \(pidVal)")
                return pidVal.clamped(to: 0...100)
            }

            if let cidDefault = cidEntry["d"] as? Int {
                OrionLogger.debug("iOSSamplingManager: resolved c[\(cid)].d = \(cidDefault)")
                return cidDefault.clamped(to: 0...100)
            }
        }

        if let globalDefault = config["d"] as? Int {
            OrionLogger.debug("iOSSamplingManager: resolved global d = \(globalDefault)")
            return globalDefault.clamped(to: 0...100)
        }

        return 100
    }
}

// MARK: - Comparable clamp helper
// Defined here once for the whole SDK — add this file if no other file has it.
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
