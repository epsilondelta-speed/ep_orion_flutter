import Foundation
import Network

/// SendData — Sends beacon JSON to the Orion backend.
///
/// V2 changes (mirror of SendData.kt Phase 2 work):
///
/// 1. Crash beacons go through `shouldSendCrashAnr()` instead of unconditional
///    bypass. The new policy:
///        s == 0  → drop (kill switch honored)
///        s > 10  → always send (crash signal preserved at typical rates)
///        s ≤ 10  → roll dice at s%
///    Previously crash beacons skipped sampling entirely, which meant the
///    kill switch couldn't actually kill anything when a customer's app
///    started crashing.
///
/// 2. `cf` snapshot ({s, sa, crm, cv}) attached to every beacon in
///    `appendCommonFields`, but ONLY if not already set by the caller.
///    FlutterSendData.swift sets `cf` from a snapshot it captured before
///    the beacon was constructed (so the same snapshot drives both filter
///    decision and cf reporting). Native callers that don't pre-populate
///    get the current snapshot at send time. The nil-check ensures we
///    never overwrite a caller's already-consistent value.
///
/// Carryover from previous version:
///
/// 1. URLSession singleton — single shared instance instead of per-beacon
///    creation. Significant overhead reduction.
///
/// 2. coronaGoForced() bypasses iOS sampling — used by FlutterSendData
///    because Dart already gated this beacon. Without this, double-sampling
///    silently under-delivers (e.g. 80% Dart × 90% iOS = 72% actual).
///
/// 3. OrionLogger used consistently — no raw print() calls.
final class SendData {

    // MARK: - Constants
    // Beacon URL is owned by iOSSamplingManager (1.2.22) — per-company `bu`
    // override with hardcoded default fallback. Read via the .shared singleton.
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
    /// - Regular beacons (no `beaconType` or `beaconType != "crash"`): use
    ///   `shouldSend()` — full dice-roll sampling.
    /// - Crash/ANR beacons (`beaconType == "crash"`): use `shouldSendCrashAnr()`
    ///   — lenient policy that always sends above 10% and honors the kill
    ///   switch. Mirrors SamplingManager.kt.
    ///
    /// Use this for any beacon that originates purely from Swift without a
    /// prior Dart-side sampling decision (e.g. native crash handler).
    func coronaGo(_ data: [String: Any]) {
        // Kill switch — when SDK is disabled at runtime, drop all beacons
        // except crash/ANR (those use sendBeaconDirect which bypasses this).
        // Matches Android EdOrion.disable()/.enable() contract. Added 1.2.22.
        guard !OrionFlutterPlugin.isDisabled else {
            OrionLogger.debug("SendData.coronaGo: skipping - SDK disabled")
            return
        }
        var payload = data

        let beaconType = payload["beaconType"] as? String ?? "screen"
        let isCrash    = beaconType == "crash"

        // ✅ V2: crash beacons get the lenient gate, not unconditional pass.
        let allowed = isCrash
            ? iOSSamplingManager.shared.shouldSendCrashAnr()
            : iOSSamplingManager.shared.shouldSend()

        if !allowed {
            let kind = isCrash ? "crash" : "beacon"
            OrionLogger.debug("SendData: \(kind) dropped by sampling (effective \(iOSSamplingManager.shared.getEffectivePercent())%)")
            return
        }

        appendCommonFields(&payload)
        post(payload)
    }

    /// Send a beacon that BYPASSES the iOS native sampling gate.
    ///
    /// Use in FlutterSendData — the beacon already passed the Dart-side
    /// SamplingManager before arriving here via the method channel. Applying
    /// a second independent sampling roll would silently under-deliver.
    ///
    /// Network connectivity is still checked; if there is no connection the
    /// beacon is dropped (nothing can be done without network).
    ///
    /// Crash beacons must NOT use this path — they should use `coronaGo()`
    /// with `beaconType = "crash"`, which now applies the lenient
    /// `shouldSendCrashAnr()` policy.
    func coronaGoForced(_ data: [String: Any]) {
        // Kill switch — when SDK is disabled at runtime, drop all beacons
        // except crash/ANR (those use sendBeaconDirect which bypasses this).
        // Matches Android EdOrion.disable()/.enable() contract. Added 1.2.22.
        guard !OrionFlutterPlugin.isDisabled else {
            OrionLogger.debug("SendData.coronaGoForced: skipping — SDK disabled")
            return
        }
        var payload = data
        // Sampling deliberately skipped — Dart already decided to send.
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

        // ✅ V2: cf snapshot. Only set if the caller hasn't already populated
        //    it. FlutterSendData captures the snapshot before constructing the
        //    beacon (so the same snapshot drives both filter decision and cf
        //    reporting); honoring its pre-populated value preserves that
        //    consistency. Native callers without a pre-existing cf get the
        //    current snapshot at send time.
        if payload["cf"] == nil {
            payload["cf"] = iOSSamplingManager.shared.getConfigSnapshot()
        }
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
        guard let url = URL(string: iOSSamplingManager.shared.beaconURL) else {
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

    /// SDK version — read from the SDK bundle's CFBundleShortVersionString so it
    /// is always in sync with the podspec version, exactly as Android reads it from
    /// BuildConfig.ORION_SDK_VERSION (injected by build.gradle's orionSdkVersion).
    /// Falls back to a hardcoded string only if the bundle lookup fails.
    static let sdkVersion: String = {
        // Bundle.module refers to the resource bundle for the Swift package / pod.
        // For a CocoaPod, Bundle(for:) with any class from the SDK resolves the
        // correct bundle even when the pod is embedded as a static or dynamic framework.
        let bundle = Bundle(identifier: "co.epsilondelta.orion-flutter")
            ?? Bundle(for: OrionFlutterPluginMarker.self)
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.10"
    }()
}

// Marker class used solely for Bundle(for:) lookup above.
// Must be in the same module as OrionFlutterPlugin.
private final class OrionFlutterPluginMarker {}