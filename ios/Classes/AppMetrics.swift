import Foundation
import UIKit
import CryptoKit

/// AppMetrics — Collects static device info and runtime metrics.
/// Mirrors AppRuntimeMetrics.kt + adds iOS-specific health fields.
///
/// Fixes applied:
///
/// 1. Duplicate iosHealth removed from getAppMetrics().
///    FlutterSendData.sendFlutterScreenMetrics() already sets
///    beacon["iosHealth"] before merging staticMetrics, and the merge uses
///    `if beacon[key] == nil` so the duplicate from AppMetrics was discarded
///    anyway.  Calling iOSHealthTracker.shared.getSessionMetrics() twice per
///    beacon (once in FlutterSendData, once in AppMetrics) wastes CPU.
///    AppMetrics.getAppMetrics() no longer includes iosHealth; FlutterSendData
///    remains the single injection point.
///
/// 2. batteryPercent() — UIDevice.current.batteryLevel must be called on the
///    main thread.  getRuntimeMetrics() is called from FlutterSendData (platform
///    thread).  batteryPercent() now returns the value cached by
///    BatteryMetricsTracker, which updates via main-thread notifications.
final class AppMetrics {

    // MARK: - Singleton
    static let shared = AppMetrics()
    private init() {}

    // MARK: - Config
    var companyId:      String = ""
    var projectId:      String = ""
    var appVersion:     String = ""
    var sdkReleaseName: String = "1.0.8"

    private var iOSVersion: Int {
        return Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "16") ?? 16
    }

    // MARK: - Full App Metrics (for beacon merging)

    func getAppMetrics() -> [String: Any] {
        let screen       = UIScreen.main
        let bounds       = screen.bounds
        let scale        = screen.scale
        let nativeBounds = screen.nativeBounds

        let deviceWidthPx  = Int(nativeBounds.width)
        let deviceHeightPx = Int(nativeBounds.height)
        let densityDpi     = Int(scale * 160)

        let deviceDimensions: [String: Any] = [
            "deviceWidth":    deviceWidthPx,
            "deviceHeight":   deviceHeightPx,
            "viewportWidth":  bounds.width,
            "viewportHeight": bounds.height,
            "densityDpi":     densityDpi,
            "density":        Double(scale)
        ]

        var metrics: [String: Any] = [
            // Device identity
            "model":            deviceModel(),
            "brand":            "Apple",
            "manufacture":      "Apple",

            // App / SDK
            "cid":              companyId,
            "pid":              projectId,
            "appVer":           appVersion,
            "appPkgName":       bundleId(),
            "sdkVer":           iOSVersion,
            "releaseName":      sdkReleaseName,

            // Screen
            "screenResolution": "\(deviceWidthPx)x\(deviceHeightPx)",
            "DeviceDimensions": deviceDimensions,

            // Device state
            "locale":           Locale.current.identifier,
            "isDeviceRooted":   isDeviceJailbroken(),

            // Session identity
            "userSessionId":    hashedDeviceId()

            // ✅ iosHealth REMOVED from here.
            //    FlutterSendData is the single injection point (one call per beacon).
            //    AppMetrics.getAppMetrics() is merged with `if beacon[key] == nil`
            //    so a duplicate here would be silently discarded anyway.
        ]

        // Runtime metrics
        for (key, value) in getRuntimeMetrics() {
            metrics[key] = value
        }

        return metrics
    }

    // MARK: - Runtime Metrics

    func getRuntimeMetrics() -> [String: Any] {
        return [
            "memoryUsage":       memoryUsagePercent(),
            "batteryPercentage": batteryPercent(),
            "diskSpaceUsage":    diskUsagePercent()
        ]
    }

    // MARK: - Device Model

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return marketingName(for: machine) ?? machine
    }

    private func marketingName(for id: String) -> String? {
        let map: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro",      "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 Mini",     "iPhone14,5": "iPhone 13",
            "iPhone15,2": "iPhone 14 Pro",      "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14",          "iPhone14,8": "iPhone 14 Plus",
            "iPhone16,1": "iPhone 15 Pro",      "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",          "iPhone15,5": "iPhone 15 Plus",
            "iPhone17,1": "iPhone 16 Pro",      "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",          "iPhone17,4": "iPhone 16 Plus",
            "i386": "Simulator", "x86_64": "Simulator", "arm64": "Simulator"
        ]
        return map[id]
    }

    private func bundleId() -> String {
        return Bundle.main.bundleIdentifier ?? "unknown"
    }

    // MARK: - Hashed Device ID

    private func hashedDeviceId() -> String {
        let key = "orion_hashed_device_id"
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            return cached
        }
        let rawId  = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let hashed = sha256(rawId)
        UserDefaults.standard.set(hashed, forKey: key)
        return hashed
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Jailbreak Detection

    private func isDeviceJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ["/Applications/Cydia.app",
                "/Library/MobileSubstrate/MobileSubstrate.dylib",
                "/bin/bash", "/usr/sbin/sshd",
                "/etc/apt", "/private/var/lib/apt/"]
            .contains { FileManager.default.fileExists(atPath: $0) }
        #endif
    }

    // MARK: - Memory % (device RAM — safe from any thread)

    private func memoryUsagePercent() -> Int {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return 0 }
        var info  = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int((UInt64(info.resident_size) * 100) / total)
    }

    // MARK: - Battery % (thread-safe)

    private func batteryPercent() -> Int {
        // ✅ UIDevice.current.batteryLevel must be read on the main thread.
        //    BatteryMetricsTracker caches the value via UIDevice battery change
        //    notifications (which fire on the main thread) so the cached value
        //    is safe to read here from any thread.
        return BatteryMetricsTracker.shared.getSessionMetrics()["sessionBatteryCurrent"] as? Int ?? -1
    }

    // MARK: - Disk % (safe from any thread)

    private func diskUsagePercent() -> Int {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let total = attrs[.systemSize]     as? Int64,
            let free  = attrs[.systemFreeSize] as? Int64,
            total > 0
        else { return -1 }
        return Int((Double(total - free) / Double(total)) * 100)
    }
}
