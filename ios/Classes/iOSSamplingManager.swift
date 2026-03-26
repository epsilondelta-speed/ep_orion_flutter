import Foundation

/// iOSSamplingManager — Native-side sampling gate for iOS.
/// Mirrors SamplingManager.kt in Android.
///
/// This covers crash beacons sent directly from Swift (handleTrackError,
/// NSSetUncaughtExceptionHandler) which bypass the Dart sampling gate.
/// Screen beacons are already gated in Dart's SamplingManager.
///
/// Resolution priority (mirrors Android exactly):
///   1. c[cid].p[pid]  → product-level override
///   2. c[cid].d       → company default
///   3. d              → global default
///   4. localRate      → fallback if CDN unreachable
final class iOSSamplingManager {

    // MARK: - Singleton
    static let shared = iOSSamplingManager()
    private init() {}

    // MARK: - Constants
    private let cdnURL         = "https://cdn.epsilondelta.co/orion/confOriSampl.json"
    private let refreshInterval: TimeInterval = 15 * 60  // 15 minutes
    private let fetchTimeout:    TimeInterval = 10

    // MARK: - State
    private var cid:             String  = ""
    private var pid:             String  = ""
    private var localRate:       Int     = 100  // 0-100
    private var remotePercent:   Int?    = nil
    private var firstBeaconSent: Bool    = false
    private var configLoaded:    Bool    = false
    private var refreshTimer:    Timer?  = nil
    private let lock =           NSLock()

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

        // Fire-and-forget CDN fetch
        fetchConfig()

        // Refresh every 15 min
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval,
                                            repeats: true) { [weak self] _ in
            self?.fetchConfig()
        }

        OrionLogger.debug("iOSSamplingManager: initialized cid=\(cid) pid=\(pid) localRate=\(localRatePercent)%")
    }

    // MARK: - Main Decision (mirrors SamplingManager.kt shouldSendSample)

    func shouldSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Rule 1 — first beacon always sends
        if !firstBeaconSent {
            firstBeaconSent = true
            OrionLogger.debug("iOSSamplingManager: first beacon — always send")
            return true
        }

        let percent = remotePercent ?? localRate

        if percent >= 100 { return true  }
        if percent <= 0   { return false }

        let roll = Int.random(in: 1...100)
        let send = roll <= percent
        OrionLogger.debug("iOSSamplingManager: roll=\(roll) percent=\(percent) → \(send ? "SEND" : "DROP")")
        return send
    }

    func getEffectivePercent() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return remotePercent ?? localRate
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - CDN Fetch

    private func fetchConfig() {
        guard let url = URL(string: cdnURL) else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = fetchTimeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
        }
        task.resume()
    }

    // MARK: - Resolution Logic (mirrors Dart SamplingManager._resolvePercent)

    private func resolvePercent(_ config: [String: Any]) -> Int {
        // Step 1: c[cid].p[pid]
        if !cid.isEmpty,
           let cidEntry = (config["c"] as? [String: Any])?[cid] as? [String: Any] {

            if !pid.isEmpty,
               let pidVal = (cidEntry["p"] as? [String: Any])?[pid] as? Int {
                OrionLogger.debug("iOSSamplingManager: resolved c[\(cid)].p[\(pid)] = \(pidVal)")
                return pidVal.clamped(to: 0...100)
            }

            // Step 2: c[cid].d
            if let cidDefault = cidEntry["d"] as? Int {
                OrionLogger.debug("iOSSamplingManager: resolved c[\(cid)].d = \(cidDefault)")
                return cidDefault.clamped(to: 0...100)
            }
        }

        // Step 3: global d
        if let globalDefault = config["d"] as? Int {
            OrionLogger.debug("iOSSamplingManager: resolved global d = \(globalDefault)")
            return globalDefault.clamped(to: 0...100)
        }

        // Step 4: default 100
        return 100
    }
}

// MARK: - Comparable clamp helper
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
