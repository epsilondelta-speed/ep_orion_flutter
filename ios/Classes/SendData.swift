import Foundation
import Network

/// SendData — Sends beacon JSON to the Orion backend.
///
/// Fixes applied:
///
/// 1. URLSession singleton — previously a new URLSession (with its own thread
///    pool and connection pool) was created on EVERY beacon send.  URLSession
///    is expensive; reusing a single shared instance reduces overhead.
///
/// 2. coronaGoForced() — Screen beacons from Dart already passed the Dart-side
///    SamplingManager before reaching Swift via the method channel.  Calling
///    iOSSamplingManager.shared.shouldSend() again inside coronaGo() creates a
///    double-sampling problem (e.g. 80% Dart × 90% iOS = 72% actual).
///    coronaGoForced() attaches metadata and posts the beacon without the
///    redundant second sampling roll.  Use it in FlutterSendData.
///    coronaGo() retains the sampling gate for native-only beacons (crash,
///    health signals sent directly from Swift without a prior Dart gate).
///
/// 3. OrionLogger used consistently throughout — no raw print() calls.
final class SendData {

    // MARK: - Constants
    private static let beaconURL          = "https://www.ed-sys.net/oriData"
    private static let connectTimeoutSec: TimeInterval = 10
    private static let readTimeoutSec:    TimeInterval = 10

    // MARK: - Shared URLSession
    // ✅ Singleton — allocated once; avoids per-beacon thread/connection pool
    //    allocation that the old `URLSession(configuration:)` inside httpsPost() caused.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = connectTimeoutSec
        config.timeoutIntervalForResource = readTimeoutSec
        return URLSession(configuration: config)
    }()

    // MARK: - Network Monitor
    private static let pathMonitor = NWPathMonitor()
    private static var currentNetworkStatus: NWPath.Status = .satisfied
    static var currentNetworkType: String = "wifi"
    private static var monitorStarted = false

    static func startNetworkMonitor() {
        guard !monitorStarted else { return }
        monitorStarted = true
        pathMonitor.pathUpdateHandler = { path in
            currentNetworkStatus = path.status
            if path.usesInterfaceType(.wifi) {
                currentNetworkType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                currentNetworkType = "data"
            } else if path.usesInterfaceType(.wiredEthernet) {
                currentNetworkType = "eth"
            } else {
                currentNetworkType = path.status == .satisfied ? "other" : "NA"
            }
            OrionLogger.debug("SendData: Network status=\(path.status) type=\(currentNetworkType)")
        }
        pathMonitor.start(queue: DispatchQueue(label: "orion.network.monitor"))
        OrionLogger.debug("SendData: Network monitor started")
    }

    // MARK: - Public API

    /// Send a beacon that is subject to the iOS native sampling gate.
    ///
    /// Use for crash beacons and any beacon that originates purely from Swift
    /// without a prior Dart-side sampling decision.
    ///
    /// Crash beacons set beaconType = "crash" and bypass sampling automatically.
    func coronaGo(_ data: [String: Any]) {
        var payload = data

        // Sampling gate — only for non-crash, native-originated beacons.
        let beaconType = payload["beaconType"] as? String ?? "screen"
        let isCrash    = beaconType == "crash"

        if !isCrash && !iOSSamplingManager.shared.shouldSend() {
            OrionLogger.debug("SendData: beacon dropped by sampling (\(iOSSamplingManager.shared.getEffectivePercent())%)")
            return
        }

        appendCommonFields(&payload)
        post(payload)
    }

    /// Send a beacon that BYPASSES the iOS native sampling gate.
    ///
    /// Use in FlutterSendData — the beacon already passed the Dart-side
    /// SamplingManager before arriving here via the method channel.  Applying
    /// a second independent sampling roll would silently under-deliver.
    ///
    /// Network connectivity is still checked; if there is no connection the
    /// beacon is dropped (nothing can be done without network).
    ///
    /// Crash beacons must NOT use this — they use coronaGo() with beaconType
    /// "crash" which already skips sampling.
    func coronaGoForced(_ data: [String: Any]) {
        var payload = data
        // ✅ Sampling deliberately skipped — Dart already decided to send.
        appendCommonFields(&payload)
        post(payload)
    }

    // MARK: - Private helpers

    private func appendCommonFields(_ payload: inout [String: Any]) {
        payload["netType"]     = Self.currentNetworkType
        payload["libVer"]      = OrionConfig.sdkVersion
        payload["sesId"]       = SessionManager.getSessionId()
        payload["platform"]    = "ios"
        payload["startupType"] = StartupTypeTracker.shared.getStartupType()
    }

    private func post(_ payload: [String: Any]) {
        if OrionLogger.isEnabled {
            if let jsonData   = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                OrionLogger.debug("SendData: 📤 BEACON:\n\(jsonString)")
            }
        }

        guard Self.currentNetworkStatus == .satisfied else {
            OrionLogger.debug("SendData: beacon dropped — no network")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            SessionManager.updateSessionTimestamp()
            self.httpsPost(payload)
        }
    }

    // MARK: - HTTP POST

    private func httpsPost(_ data: [String: Any]) {
        guard let url = URL(string: Self.beaconURL) else {
            OrionLogger.error("SendData: Invalid beacon URL")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(OrionConfig.companyId, forHTTPHeaderField: "cid")
            request.httpBody = jsonData
            // Timeouts are set on sharedSession's configuration — no need to repeat here.

            // ✅ Reuse the shared session instead of creating a new one per request.
            let task = Self.sharedSession.dataTask(with: request) { _, response, error in
                if let error = error {
                    OrionLogger.error("SendData: beacon send failed — \(error.localizedDescription)")
                    return
                }
                if let http = response as? HTTPURLResponse {
                    OrionLogger.debug("SendData: beacon sent — HTTP \(http.statusCode)")
                }
            }
            task.resume()

        } catch {
            OrionLogger.error("SendData: JSON serialization error", error)
        }
    }
}

// MARK: - OrionConfig

struct OrionConfig {
    static var companyId: String = ""
    static var projectId: String = ""
    static let sdkVersion: String = "1.0.8"
}
