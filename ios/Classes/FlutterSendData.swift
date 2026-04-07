import Foundation

/// FlutterSendData — Assembles the full beacon JSON and sends via SendData.
/// Mirrors FlutterSendData.kt exactly + adds iOS-specific fields.
///
/// Double-sampling fix: uses coronaGoForced() instead of coronaGo().
/// The Dart SamplingManager already decided to send this beacon before calling
/// the Swift method channel.  coronaGo() would apply a second independent iOS
/// sampling roll, silently reducing delivery rate below the intended percentage.
final class FlutterSendData {

    // MARK: - Singleton
    static let shared = FlutterSendData()
    private init() {}

    // MARK: - Main entry point

    func sendFlutterScreenMetrics(
        screenName:      String,
        ttid:            Int,
        ttfd:            Int,
        ttfdManual:      Bool    = false,
        jankyFrames:     Int,
        frozenFrames:    Int,
        networkRequests: [[String: Any?]],
        frameMetrics:    [String: Any]? = nil,
        wentBg:          Bool    = false,
        bgCount:         Int     = 0,
        rageClicks:      [[String: Any]] = [],
        rageClickCount:  Int     = 0
    ) {
        MemoryMetricsTracker.shared.onScreenTransition()

        let batteryMetrics  = BatteryMetricsTracker.shared.getSessionMetrics()
        let memoryMetrics   = MemoryMetricsTracker.shared.getSessionMetrics()
        let wakeLockMetrics = WakeLockTracker.shared.getSessionMetrics()
        let staticMetrics   = AppMetrics.shared.getAppMetrics()

        var beacon: [String: Any] = [
            "flutter":      1,
            "screen":       screenName,
            "activityName": screenName,
            "ttid":         ttid,
            "ttfd":         ttfd,
            "ttfdManual":   ttfdManual,
            "jankyFrames":  jankyFrames,
            "frozenFrames": frozenFrames,
            "network":      buildNetworkArray(networkRequests),
            "wentBg":       wentBg
        ]

        if wentBg { beacon["bgCount"] = bgCount }

        if let fm = frameMetrics { beacon["frameMetrics"] = fm }

        beacon["sesBatSt"]          = batteryMetrics["sessionBatteryStart"]
        beacon["sesBatCur"]         = batteryMetrics["sessionBatteryCurrent"]
        beacon["sesBatDrain"]       = batteryMetrics["sessionBatteryDrain"]
        beacon["totalSesDurMin"]    = batteryMetrics["totalSessionDurationMin"]
        beacon["fgDurMin"]          = batteryMetrics["foregroundDurationMin"]
        beacon["bgDurMin"]          = batteryMetrics["backgroundDurationMin"]
        beacon["drainPerFgHour"]    = batteryMetrics["drainPerForegroundHour"]
        beacon["drainPerTotalHour"] = batteryMetrics["drainPerTotalHour"]
        beacon["fgPct"]             = batteryMetrics["foregroundPercentage"]
        beacon["sesTimedOut"]       = batteryMetrics["sessionTimedOut"]
        beacon["batIsCharging"]     = batteryMetrics["isCharging"]

        beacon["mem"] = memoryMetrics

        if !wakeLockMetrics.isEmpty { beacon["wl"] = wakeLockMetrics }

        if rageClickCount > 0 {
            beacon["rageClicks"]     = buildRageClicksArray(rageClicks)
            beacon["rageClickCount"] = rageClickCount
        }

        // iOS-specific health — not in Android beacons.
        // Set here explicitly; AppMetrics.getAppMetrics() no longer duplicates it
        // so there is exactly one call to iOSHealthTracker.getSessionMetrics() per beacon.
        beacon["iosHealth"] = iOSHealthTracker.shared.getSessionMetrics()

        // Merge static device/app metrics (don't overwrite existing keys).
        for (key, value) in staticMetrics {
            if beacon[key] == nil { beacon[key] = value }
        }

        OrionLogger.debug("FlutterSendData: 📤 Sending beacon for '\(screenName)'")

        // ✅ coronaGoForced — Dart SamplingManager already gated this beacon.
        //    Using coronaGo() would apply a second independent iOS sampling roll,
        //    e.g. 80% Dart × 90% iOS = 72% actual delivery (not 80%).
        SendData().coronaGoForced(beacon)
    }

    // MARK: - Network Array Builder

    private func buildNetworkArray(_ requests: [[String: Any?]]) -> [[String: Any]] {
        return requests.compactMap { req in
            var obj: [String: Any] = [
                "url":        req["url"]        as? String ?? "",
                "method":     req["method"]     as? String ?? "",
                "statusCode": (req["statusCode"] as? NSNumber)?.intValue ?? -1,
                "startTime":  (req["startTime"]  as? NSNumber)?.int64Value ?? 0,
                "endTime":    (req["endTime"]    as? NSNumber)?.int64Value ?? 0,
                "duration":   (req["duration"]   as? NSNumber)?.intValue ?? 0
            ]
            if let ps = req["payloadSize"]  as? NSNumber { obj["payloadSize"]  = ps.intValue }
            if let em = req["errorMessage"] as? String   { obj["errorMessage"] = em }
            if let at = req["actualTime"]   as? NSNumber { obj["actualTime"]   = at.intValue }
            if let rt = req["responseType"] as? String   { obj["responseType"] = rt }
            if let ct = req["contentType"]  as? String   { obj["contentType"]  = ct }
            return obj
        }
    }

    // MARK: - Rage Clicks Array Builder

    private func buildRageClicksArray(_ clicks: [[String: Any]]) -> [[String: Any]] {
        return clicks.compactMap { click in
            guard
                let x   = (click["x"]     as? NSNumber)?.intValue,
                let y   = (click["y"]     as? NSNumber)?.intValue,
                let cnt = (click["count"] as? NSNumber)?.intValue
            else { return nil }
            return [
                "x":      x,
                "y":      y,
                "count":  cnt,
                "durMs":  (click["durMs"] as? NSNumber)?.intValue ?? 0,
                "ts":     (click["ts"]    as? NSNumber)?.int64Value ?? 0
            ]
        }
    }
}
