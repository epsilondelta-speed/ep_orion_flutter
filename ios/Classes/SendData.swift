import Foundation
import Network

/// SendData — Sends beacon JSON to the Orion backend.
/// No GZIP — server reads raw body directly into RabbitMQ queue.
final class SendData {

    // MARK: - Constants
    private static let beaconURL         = "https://www.ed-sys.net/oriData"
    private static let connectTimeoutSec: TimeInterval = 10
    private static let readTimeoutSec:    TimeInterval = 10

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

    func coronaGo(_ data: [String: Any]) {
        var payload = data

        // ✅ Sampling gate — mirrors Android SamplingManager.shouldSendSample()
        // Only applies to non-crash beacons triggered from native side
        // Screen beacons are already gated in Dart before reaching here
        let beaconType = payload["beaconType"] as? String ?? "screen"
        let isCrash    = beaconType == "crash"

        if !isCrash && !iOSSamplingManager.shared.shouldSend() {
            OrionLogger.debug("SendData: beacon dropped by sampling (\(iOSSamplingManager.shared.getEffectivePercent())%)")
            return
        }

        // Attach standard metadata
        payload["netType"]     = Self.currentNetworkType
        payload["libVer"]      = OrionConfig.sdkVersion
        payload["sesId"]       = SessionManager.getSessionId()
        payload["platform"]    = "ios"
        payload["startupType"] = StartupTypeTracker.shared.getStartupType()

        // Debug print full beacon
        if let jsonData   = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("[Orion] 📤 BEACON:\n\(jsonString)")
        }

        // Check network
        guard Self.currentNetworkStatus == .satisfied else {
            print("[Orion] ⚠️ BEACON DROPPED — no network")
            return
        }

        // Send on background queue
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
            request.setValue(OrionConfig.companyId,             forHTTPHeaderField: "cid")
            request.httpBody        = jsonData
            request.timeoutInterval = Self.connectTimeoutSec

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = Self.readTimeoutSec
            let session = URLSession(configuration: config)

            let task = session.dataTask(with: request) { _, response, error in
                if let error = error {
                    print("[Orion] ❌ BEACON SEND FAILED: \(error.localizedDescription)")
                    return
                }
                if let http = response as? HTTPURLResponse {
                    print("[Orion] ✅ BEACON SENT — HTTP \(http.statusCode)")
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
