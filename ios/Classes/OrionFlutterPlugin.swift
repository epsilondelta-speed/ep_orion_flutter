import Flutter
import UIKit

/// OrionFlutterPlugin — Main entry point for the Orion iOS plugin.
/// Mirrors OrionFlutterPlugin.kt method-for-method.
public class OrionFlutterPlugin: NSObject, FlutterPlugin {

    // MARK: - Plugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "orion_flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = OrionFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
        OrionLogger.debug("OrionFlutterPlugin: registered")
    }

    // MARK: - State
    private var isInitialized         = false
    private var currentScreen:  String?
    private var batterySessionStarted = false

    // MARK: - Method Channel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initializeEdOrion":       handleInit(args: args, result: result)
        case "getPlatformVersion":      result("iOS \(UIDevice.current.systemVersion)")
        case "getRuntimeMetrics":       handleGetRuntimeMetrics(result: result)
        case "onAppForeground":         handleAppForeground(result: result)
        case "onAppBackground":         handleAppBackground(result: result)
        case "onFlutterScreenStart":    handleScreenStart(args: args, result: result)
        case "onFlutterScreenStop":     handleScreenStop(args: args, result: result)
        case "trackFlutterScreen":      handleTrackScreen(args: args, result: result)
        case "trackFlutterError":       handleTrackError(args: args, result: result)
        case "wakeLockAcquire":         handleWakeLockAcquire(args: args, result: result)
        case "wakeLockRelease":         handleWakeLockRelease(args: args, result: result)
        case "wakeLockTrackAcquire":    handleWakeLockTrackAcquire(args: args, result: result)
        case "wakeLockTrackRelease":    handleWakeLockTrackRelease(args: args, result: result)
        case "wakeLockSetStuckThreshold": handleWakeLockSetStuckThreshold(args: args, result: result)
        case "wakeLockGetActiveCount":  result(WakeLockTracker.shared.getActiveCount())
        case "wakeLockIsHeld":
            if let tag = args["tag"] as? String { result(WakeLockTracker.shared.isHeld(tag: tag)) }
            else { result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)) }
        case "wakeLockGetActiveTags":   result(WakeLockTracker.shared.getActiveTags())
        case "wakeLockLogState":        WakeLockTracker.shared.logState(); result(true)
        default:                        result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Init Handler

    private func handleInit(args: [String: Any], result: @escaping FlutterResult) {
        guard let cid = args["cid"] as? String, !cid.isEmpty else {
            result(FlutterError(code: "MISSING_CID", message: "cid is required", details: nil)); return
        }
        guard let pid = args["pid"] as? String, !pid.isEmpty else {
            result(FlutterError(code: "MISSING_PID", message: "pid is required", details: nil)); return
        }

        // Config
        OrionConfig.companyId        = cid
        OrionConfig.projectId        = pid
        AppMetrics.shared.companyId  = cid
        AppMetrics.shared.projectId  = pid
        AppMetrics.shared.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        // Initialize all subsystems
        SessionManager.initialize()
        SendData.startNetworkMonitor()
        MemoryMetricsTracker.shared.initialize()
        BatteryMetricsTracker.shared.initialize()
        WakeLockTracker.shared.initialize()
        UIDevice.current.isBatteryMonitoringEnabled = true

        // ✅ New subsystems
        iOSHealthTracker.shared.initialize()
        StartupTypeTracker.shared.detectStartupType()
        iOSSamplingManager.shared.initialize(cid: cid, pid: pid)

        // ✅ Native crash handler
        NSSetUncaughtExceptionHandler { exception in
            var beacon: [String: Any] = [
                "source":           "ios_native",
                "crashType":        exception.name.rawValue,
                "beaconType":       "crash",
                "activity":         "NativeCrash",
                "localizedMessage": exception.reason ?? "Unknown",
                "stackTrace":       exception.callStackSymbols.joined(separator: "\n"),
                "epoch":            Int64(Date().timeIntervalSince1970 * 1000),
                "cid":              OrionConfig.companyId,
                "pid":              OrionConfig.projectId,
                "flutter":          1,
                "iosHealth":        iOSHealthTracker.shared.getSessionMetrics()
            ]
            let staticMetrics = AppMetrics.shared.getAppMetrics()
            for (key, value) in staticMetrics {
                if beacon[key] == nil { beacon[key] = value }
            }
            SendData().coronaGo(beacon)
            Thread.sleep(forTimeInterval: 0.5)
        }

        isInitialized = true
        OrionLogger.debug("OrionFlutterPlugin: Initialized — cid=\(cid), pid=\(pid)")
        result("orion_initialized")
    }

    // MARK: - Runtime Metrics

    private func handleGetRuntimeMetrics(result: @escaping FlutterResult) {
        var metrics = AppMetrics.shared.getRuntimeMetrics()
        // Add iOS health to runtime metrics
        metrics["iosHealth"] = iOSHealthTracker.shared.getSessionMetrics()
        if let jsonData   = try? JSONSerialization.data(withJSONObject: metrics),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            result(jsonString)
        } else {
            result("Not available")
        }
    }

    // MARK: - Lifecycle

    private func handleAppForeground(result: @escaping FlutterResult) {
        OrionLogger.debug("OrionFlutterPlugin: App foregrounded")
        BatteryMetricsTracker.shared.onAppForegrounded()
        WakeLockTracker.shared.onAppForeground()
        batterySessionStarted = true
        result("app_foreground_tracked")
    }

    private func handleAppBackground(result: @escaping FlutterResult) {
        guard batterySessionStarted else { result("app_background_skipped"); return }
        OrionLogger.debug("OrionFlutterPlugin: App backgrounded")
        BatteryMetricsTracker.shared.onAppBackgrounded()
        WakeLockTracker.shared.onAppBackground()
        // ✅ Save exit timestamp for startup type detection next launch
        StartupTypeTracker.shared.saveExitTimestamp()
        result("app_background_tracked")
    }

    private func handleScreenStart(args: [String: Any], result: @escaping FlutterResult) {
        let screen = args["screen"] as? String ?? "Unknown"
        currentScreen = screen
        if !batterySessionStarted {
            BatteryMetricsTracker.shared.onAppForegrounded()
            batterySessionStarted = true
        }
        result("flutter_screen_start_tracked")
    }

    private func handleScreenStop(args: [String: Any], result: @escaping FlutterResult) {
        let screen = args["screen"] as? String ?? "Unknown"
        if currentScreen == screen { currentScreen = nil }
        result("flutter_screen_stop_tracked")
    }

    // MARK: - Screen Beacon

    private func handleTrackScreen(args: [String: Any], result: @escaping FlutterResult) {
        let screenName     = args["screen"]         as? String ?? "Unknown"
        let ttid           = args["ttid"]           as? Int ?? -1
        let ttfd           = args["ttfd"]           as? Int ?? -1
        let ttfdManual     = args["ttfdManual"]     as? Bool ?? false
        let jankyFrames    = args["jankyFrames"]    as? Int ?? 0
        let frozenFrames   = args["frozenFrames"]   as? Int ?? 0
        let network        = args["network"]        as? [[String: Any?]] ?? []
        let frameMetrics   = args["frameMetrics"]   as? [String: Any]
        let wentBg         = args["wentBg"]         as? Bool ?? false
        let bgCount        = args["bgCount"]        as? Int ?? 0
        let rageClicks     = args["rageClicks"]     as? [[String: Any]] ?? []
        let rageClickCount = args["rageClickCount"] as? Int ?? 0

        OrionLogger.debug("OrionFlutterPlugin: trackFlutterScreen — screen=\(screenName), rageClicks=\(rageClickCount)")
        OrionLogger.debug("📤 trackFlutterScreen called for: \(screenName)")

        FlutterSendData.shared.sendFlutterScreenMetrics(
            screenName:      screenName,
            ttid:            ttid,
            ttfd:            ttfd,
            ttfdManual:      ttfdManual,
            jankyFrames:     jankyFrames,
            frozenFrames:    frozenFrames,
            networkRequests: network,
            frameMetrics:    frameMetrics,
            wentBg:          wentBg,
            bgCount:         bgCount,
            rageClicks:      rageClicks,
            rageClickCount:  rageClickCount
        )
        result("screen_tracked")
    }

    // MARK: - Crash Handler

    private func handleTrackError(args: [String: Any], result: @escaping FlutterResult) {
        let exception = args["exception"] as? String ?? "Unknown exception"
        let stack     = args["stack"]     as? String ?? ""
        let library   = args["library"]   as? String ?? ""
        let context   = args["context"]   as? String ?? ""
        let screen    = args["screen"]    as? String ?? "UnknownScreen"
        let network   = args["network"]   as? [[String: Any]] ?? []

        OrionLogger.debug("OrionFlutterPlugin: Flutter error on '\(screen)': \(exception.prefix(120))")

        // Thread info — mirrors getThreadInformation() in Kotlin
        let threadInfo: [String: Any] = [
            "threadName":     Thread.current.name ?? "main",
            "threadState":    Thread.current.isExecuting ? "RUNNABLE" : "WAITING",
            "threadPriority": Thread.current.threadPriority
        ]

        // Environment — mirrors getEnvironmentVariables() in Kotlin
        let environment: [String: Any] = [
            "cpuNum": ProcessInfo.processInfo.activeProcessorCount,
            "mem":    AppMetrics.shared.getRuntimeMetrics()["memoryUsage"] as? Int ?? 0,
            "maxMem": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        ]

        var beacon: [String: Any] = [
            "source":           "flutter",
            "crashType":        "FlutterError",
            "beaconType":       "crash",
            "flutter":          1,
            "activity":         screen,
            "localizedMessage": exception,
            "stackTrace":       stack,
            "crashLocation":    library,
            "screenContext":    context,
            "epoch":            Int64(Date().timeIntervalSince1970 * 1000),
            "network":          network,
            "threadInfo":       threadInfo,
            "environment":      environment,
            "action":           generateActionableInsight(exception),
            "networkState":     SendData.currentNetworkType,
            "lastUserInteraction": "unknown",
            // ✅ iOS-specific health context at time of crash
            "iosHealth":        iOSHealthTracker.shared.getSessionMetrics()
        ]

        let staticMetrics = AppMetrics.shared.getAppMetrics()
        for (key, value) in staticMetrics {
            if beacon[key] == nil { beacon[key] = value }
        }

        SendData().coronaGo(beacon)
        result("flutter_error_tracked")
    }

    private func generateActionableInsight(_ message: String) -> String {
        let msg = message.lowercased()
        if msg.contains("null") || msg.contains("nil") {
            return "Check for null/nil object usage. Ensure objects are initialized before use."
        } else if msg.contains("index") || msg.contains("range") {
            return "Check for index bounds. Validate list/array size before accessing."
        } else if msg.contains("state") {
            return "Check widget lifecycle. Ensure setState is not called after dispose."
        } else if msg.contains("overflow") {
            return "Check for layout issues. Consider Expanded, Flexible, or SingleChildScrollView."
        } else if msg.contains("network") || msg.contains("socket") {
            return "Check network connectivity and API endpoints."
        } else if msg.contains("permission") {
            return "Check app permissions in Info.plist."
        } else {
            return "Refer to stack trace and logs for debugging."
        }
    }

    // MARK: - Wake Lock Handlers

    private func handleWakeLockAcquire(args: [String: Any], result: @escaping FlutterResult) {
        guard let tag = args["tag"] as? String else {
            result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)); return
        }
        result(WakeLockTracker.shared.acquire(tag: tag, timeoutMs: args["timeoutMs"] as? Int))
    }

    private func handleWakeLockRelease(args: [String: Any], result: @escaping FlutterResult) {
        guard let tag = args["tag"] as? String else {
            result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)); return
        }
        WakeLockTracker.shared.release(tag: tag); result(true)
    }

    private func handleWakeLockTrackAcquire(args: [String: Any], result: @escaping FlutterResult) {
        guard let tag = args["tag"] as? String else {
            result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)); return
        }
        WakeLockTracker.shared.trackAcquire(tag: tag, timeoutMs: args["timeoutMs"] as? Int); result(true)
    }

    private func handleWakeLockTrackRelease(args: [String: Any], result: @escaping FlutterResult) {
        guard let tag = args["tag"] as? String else {
            result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)); return
        }
        WakeLockTracker.shared.trackRelease(tag: tag); result(true)
    }

    private func handleWakeLockSetStuckThreshold(args: [String: Any], result: @escaping FlutterResult) {
        guard let thresholdMs = args["thresholdMs"] as? Int else {
            result(FlutterError(code: "MISSING_THRESHOLD", message: "thresholdMs required", details: nil)); return
        }
        WakeLockTracker.shared.stuckThresholdMs = thresholdMs; result(true)
    }
}

// MARK: - App Lifecycle (UIApplicationDelegate)

extension OrionFlutterPlugin {

    public func applicationDidBecomeActive(_ application: UIApplication) {
        if batterySessionStarted {
            BatteryMetricsTracker.shared.onAppForegrounded()
            WakeLockTracker.shared.onAppForeground()
        }
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        if batterySessionStarted {
            BatteryMetricsTracker.shared.onAppBackgrounded()
            WakeLockTracker.shared.onAppBackground()
            StartupTypeTracker.shared.saveExitTimestamp()
        }
    }
}
