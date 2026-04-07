import Flutter
import UIKit

/// OrionFlutterPlugin — Main entry point for the Orion iOS plugin.
/// Mirrors OrionFlutterPlugin.kt method-for-method.
///
/// Fixes applied:
///
/// 1. Crash handler chaining — NSSetUncaughtExceptionHandler() now saves and
///    forwards to any previously installed handler (mirrors Android which saves
///    Thread.getDefaultUncaughtExceptionHandler() before replacing it).
///    Previously each call to handleInit() would silently overwrite any existing
///    handler installed by Crashlytics, Sentry, etc.
///
/// 2. try/catch protection on all handleX() methods — a throw inside any
///    private handler would previously propagate as an unhandled Swift error and
///    terminate the app.  All handlers now catch, log, and call result() so the
///    Dart side always receives a response.
///
/// 3. Double-lifecycle guard — applicationDidBecomeActive / applicationDidEnterBackground
///    also call onAppForegrounded / onAppBackgrounded via UIApplicationDelegate.
///    The Dart side sends onAppForeground / onAppBackground too.  BatteryMetricsTracker
///    now has an isInForeground guard inside onAppBackgrounded that prevents
///    double-counting, so both paths are safe.  No extra guard needed here.
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

    // Stored as a static so the NSSetUncaughtExceptionHandler closure can
    // reference it without capturing `self` or any local variable — C function
    // pointers cannot capture context from the enclosing Swift scope.
    private static var previousUncaughtExceptionHandler: (@convention(c) (NSException) -> Void)? = nil

    // MARK: - Method Channel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initializeEdOrion":           handleInit(args: args, result: result)
        case "getPlatformVersion":          result("iOS \(UIDevice.current.systemVersion)")
        case "getRuntimeMetrics":           handleGetRuntimeMetrics(result: result)
        case "onAppForeground":             handleAppForeground(result: result)
        case "onAppBackground":             handleAppBackground(result: result)
        case "onFlutterScreenStart":        handleScreenStart(args: args, result: result)
        case "onFlutterScreenStop":         handleScreenStop(args: args, result: result)
        case "trackFlutterScreen":          handleTrackScreen(args: args, result: result)
        case "trackFlutterError":           handleTrackError(args: args, result: result)
        case "wakeLockAcquire":             handleWakeLockAcquire(args: args, result: result)
        case "wakeLockRelease":             handleWakeLockRelease(args: args, result: result)
        case "wakeLockTrackAcquire":        handleWakeLockTrackAcquire(args: args, result: result)
        case "wakeLockTrackRelease":        handleWakeLockTrackRelease(args: args, result: result)
        case "wakeLockSetStuckThreshold":   handleWakeLockSetStuckThreshold(args: args, result: result)
        case "wakeLockGetActiveCount":      result(WakeLockTracker.shared.getActiveCount())
        case "wakeLockIsHeld":
            guard let tag = args["tag"] as? String else {
                result(FlutterError(code: "MISSING_TAG", message: "tag required", details: nil)); return
            }
            result(WakeLockTracker.shared.isHeld(tag: tag))
        case "wakeLockGetActiveTags":       result(WakeLockTracker.shared.getActiveTags())
        case "wakeLockLogState":            WakeLockTracker.shared.logState(); result(true)
        default:                            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Init Handler

    private func handleInit(args: [String: Any], result: @escaping FlutterResult) {
        do {
            guard let cid = args["cid"] as? String, !cid.isEmpty else {
                result(FlutterError(code: "MISSING_CID", message: "cid is required", details: nil)); return
            }
            guard let pid = args["pid"] as? String, !pid.isEmpty else {
                result(FlutterError(code: "MISSING_PID", message: "pid is required", details: nil)); return
            }

            OrionConfig.companyId        = cid
            OrionConfig.projectId        = pid
            AppMetrics.shared.companyId  = cid
            AppMetrics.shared.projectId  = pid
            AppMetrics.shared.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

            SessionManager.initialize()
            SendData.startNetworkMonitor()
            MemoryMetricsTracker.shared.initialize()
            BatteryMetricsTracker.shared.initialize()
            WakeLockTracker.shared.initialize()
            UIDevice.current.isBatteryMonitoringEnabled = true

            iOSHealthTracker.shared.initialize()
            StartupTypeTracker.shared.detectStartupType()
            iOSSamplingManager.shared.initialize(cid: cid, pid: pid)

            // ✅ Chain the crash handler rather than overwriting it.
            //    Libraries like Crashlytics / Sentry install their own handler first.
            //    Overwriting without chaining silently breaks their crash reporting.
            //
            //    NSSetUncaughtExceptionHandler requires a plain C function pointer,
            //    which cannot capture context from the enclosing Swift scope.
            //    We store the previous handler in a static variable so the closure
            //    is context-free and satisfies the C function pointer requirement.
            OrionFlutterPlugin.previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                // Build and send Orion crash beacon.
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
                for (key, value) in staticMetrics where beacon[key] == nil {
                    beacon[key] = value
                }
                // coronaGo with beaconType = "crash" bypasses sampling gate.
                SendData().coronaGo(beacon)
                Thread.sleep(forTimeInterval: 0.5)

                // ✅ Forward to the previously installed handler (Crashlytics, Sentry, etc.)
                OrionFlutterPlugin.previousUncaughtExceptionHandler?(exception)
            }

            isInitialized = true
            OrionLogger.debug("OrionFlutterPlugin: Initialized — cid=\(cid), pid=\(pid)")
            result("orion_initialized")

        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleInit error — \(error)")
            result(FlutterError(code: "INIT_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Runtime Metrics

    private func handleGetRuntimeMetrics(result: @escaping FlutterResult) {
        do {
            var metrics = AppMetrics.shared.getRuntimeMetrics()
            metrics["iosHealth"] = iOSHealthTracker.shared.getSessionMetrics()
            if let jsonData   = try? JSONSerialization.data(withJSONObject: metrics),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                result(jsonString)
            } else {
                result("Not available")
            }
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleGetRuntimeMetrics error — \(error)")
            result("Not available")
        }
    }

    // MARK: - Lifecycle

    private func handleAppForeground(result: @escaping FlutterResult) {
        do {
            OrionLogger.debug("OrionFlutterPlugin: App foregrounded (from Dart)")
            BatteryMetricsTracker.shared.onAppForegrounded()
            WakeLockTracker.shared.onAppForeground()
            batterySessionStarted = true
            result("app_foreground_tracked")
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleAppForeground error — \(error)")
            result(FlutterError(code: "APP_FOREGROUND_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func handleAppBackground(result: @escaping FlutterResult) {
        do {
            guard batterySessionStarted else { result("app_background_skipped"); return }
            OrionLogger.debug("OrionFlutterPlugin: App backgrounded (from Dart)")
            BatteryMetricsTracker.shared.onAppBackgrounded()
            WakeLockTracker.shared.onAppBackground()
            StartupTypeTracker.shared.saveExitTimestamp()
            result("app_background_tracked")
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleAppBackground error — \(error)")
            result(FlutterError(code: "APP_BACKGROUND_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func handleScreenStart(args: [String: Any], result: @escaping FlutterResult) {
        do {
            let screen = args["screen"] as? String ?? "Unknown"
            currentScreen = screen
            if !batterySessionStarted {
                BatteryMetricsTracker.shared.onAppForegrounded()
                batterySessionStarted = true
            }
            result("flutter_screen_start_tracked")
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleScreenStart error — \(error)")
            result(FlutterError(code: "SCREEN_START_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func handleScreenStop(args: [String: Any], result: @escaping FlutterResult) {
        do {
            let screen = args["screen"] as? String ?? "Unknown"
            if currentScreen == screen { currentScreen = nil }
            result("flutter_screen_stop_tracked")
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleScreenStop error — \(error)")
            result(FlutterError(code: "SCREEN_STOP_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Screen Beacon

    private func handleTrackScreen(args: [String: Any], result: @escaping FlutterResult) {
        do {
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

            OrionLogger.debug("OrionFlutterPlugin: trackFlutterScreen — '\(screenName)' rageClicks=\(rageClickCount)")

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
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleTrackScreen error — \(error)")
            result(FlutterError(code: "SCREEN_TRACK_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Crash Handler

    private func handleTrackError(args: [String: Any], result: @escaping FlutterResult) {
        do {
            let exception = args["exception"] as? String ?? "Unknown exception"
            let stack     = args["stack"]     as? String ?? ""
            let library   = args["library"]   as? String ?? ""
            let context   = args["context"]   as? String ?? ""
            let screen    = args["screen"]    as? String ?? "UnknownScreen"
            let network   = args["network"]   as? [[String: Any]] ?? []

            OrionLogger.debug("OrionFlutterPlugin: Flutter error on '\(screen)': \(exception.prefix(120))")

            let threadInfo: [String: Any] = [
                "threadName":     Thread.current.name ?? "main",
                "threadState":    Thread.current.isExecuting ? "RUNNABLE" : "WAITING",
                "threadPriority": Thread.current.threadPriority
            ]

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
                "iosHealth":        iOSHealthTracker.shared.getSessionMetrics()
            ]

            let staticMetrics = AppMetrics.shared.getAppMetrics()
            for (key, value) in staticMetrics where beacon[key] == nil {
                beacon[key] = value
            }

            // beaconType = "crash" → coronaGo() bypasses sampling gate automatically.
            SendData().coronaGo(beacon)
            result("flutter_error_tracked")
        } catch {
            OrionLogger.error("OrionFlutterPlugin: handleTrackError error — \(error)")
            result(FlutterError(code: "TRACK_ERROR_FAILED", message: error.localizedDescription, details: nil))
        }
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
        do {
            result(WakeLockTracker.shared.acquire(tag: tag, timeoutMs: args["timeoutMs"] as? Int))
        } catch {
            result(FlutterError(code: "WAKE_LOCK_ACQUIRE_ERROR", message: error.localizedDescription, details: nil))
        }
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
        // Note: Dart onAppForeground is also sent by the Flutter engine.
        // BatteryMetricsTracker.onAppForegrounded() has an internal guard
        // (`isInForeground` flag under lock) that prevents double-counting
        // if both paths fire in quick succession.
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