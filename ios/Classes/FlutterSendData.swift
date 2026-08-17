import Foundation

/// FlutterSendData — Assembles the full beacon JSON and sends via SendData.
/// Mirrors FlutterSendData.kt exactly + adds iOS-specific fields.
///
/// V2 changes (mirror of FlutterSendData.kt Phase 3 work):
///
/// 1. Analytics URL filtering. When iOSSamplingManager.shouldFilterAnalytics()
///    is true (i.e. the resolved `sa` field is false, the default), URLs
///    matching well-known third-party analytics hosts (Google Analytics,
///    Firebase Installations, Amplitude, Mixpanel, Segment, Snowplow,
///    AppsFlyer, Adjust, Branch, CleverTap, MoEngage, Crashlytics, Sentry,
///    app-measurement) are stripped from the beacon's `network[]` array.
///
/// 2. Orion-internal URLs (cdn.epsilondelta.co, www.ed-sys.net) are stripped
///    unconditionally — these are the SDK's own beacon-send and config-fetch
///    endpoints and shouldn't be reported as customer traffic.
///
/// 3. The `cf` field is attached to every beacon, carrying the resolved
///    sampling-config snapshot {s, sa, crm, cv} that produced this beacon.
///    Backend uses this to interpret each beacon with full context.
///
/// Carryover from the previous file:
///
/// * coronaGoForced() (not coronaGo()) — Dart's SamplingManager already
///   decided to send this beacon. Using coronaGo() would apply a second
///   independent iOS sampling roll, e.g. 80% Dart × 90% iOS = 72% actual
///   delivery instead of the intended 80%.
///
/// * iOS-specific iosHealth field set here, not in AppMetrics.getAppMetrics(),
///   to keep iOSHealthTracker.getSessionMetrics() called exactly once per beacon.
final class FlutterSendData {

    // MARK: - Singleton
    static let shared = FlutterSendData()
    private init() {}

    // MARK: - Filter host lists
    //
    // Substring match — lowercased. Mirror FlutterSendData.kt ANALYTICS_HOSTS.
    // Order doesn't matter; we just check for any match.

    private static let analyticsHosts: [String] = [
        "google-analytics.com",
        "firebaseinstallations.googleapis.com",
        "app-measurement.com",
        "crashlytics",
        "sentry.io",
        "snowplowanalytics.com",
        "snowplow",
        "segment.io",
        "segment.com",
        "mixpanel.com",
        "amplitude.com",
        "appsflyer.com",
        "adjust.com",
        "branch.io",
        "clevertap.com",
        "moengage.com"
    ]

    private static let orionInternalHosts: [String] = [
        "cdn.epsilondelta.co",
        "www.ed-sys.net"
    ]

    private static func isAnalyticsUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return analyticsHosts.contains(where: { lower.contains($0) })
    }

    private static func isOrionInternalUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return orionInternalHosts.contains(where: { lower.contains($0) })
    }

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
        rageClickCount:  Int     = 0,
        // Resolved {s, sa, crm, cv} from the Dart layer that made this beacon's
        // send/drop decision. Nil on native-origin beacons — see the cf block below.
        dartConfigSnapshot: [String: Any]? = nil
    ) {
        MemoryMetricsTracker.shared.onScreenTransition()

        // Read sampling config snapshot ONCE per beacon. The same snapshot
        // drives both the filter decision and the cf field, so they always
        // agree — backend reading cf knows exactly which filter was applied.
        let cfSnapshot      = iOSSamplingManager.shared.getConfigSnapshot()
        let filterAnalytics = iOSSamplingManager.shared.shouldFilterAnalytics()

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
            "network":      buildNetworkArray(networkRequests, filterAnalytics: filterAnalytics),
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

        // cf snapshot — added LAST so nothing else can clobber it. Carries the
        // resolved {s, sa, crm, cv} that produced this beacon.
        //
        // 1.2.33 — cf now reports the config each layer ACTUALLY ACTED UNDER.
        // The field has two owners:
        //   s, crm, cv  → Dart. Dart's shouldSend() makes the send/drop call, so
        //                 Dart's percent and config version produced this beacon.
        //   sa          → native. filterAnalytics above is applied down here, so
        //                 native's value is what shaped the network waterfall.
        //
        // Dart and native poll the same CDN file on independent timers, so a config
        // change landing between the two fetches used to give a beacon a cf that was
        // not the config that produced it. Falls back wholesale to the native
        // snapshot when Dart sent nothing.
        var resolvedCf = cfSnapshot
        if let dartCf = dartConfigSnapshot {
            if let s   = dartCf["s"]   { resolvedCf["s"]   = s }
            if let crm = dartCf["crm"] { resolvedCf["crm"] = crm }
            if let cv  = dartCf["cv"]  { resolvedCf["cv"]  = cv }
        }
        beacon["cf"] = resolvedCf

        OrionLogger.debug("FlutterSendData: 📤 Sending beacon for '\(screenName)' (filter=\(filterAnalytics))")

        // ✅ coronaGoForced — Dart SamplingManager already gated this beacon.
        SendData().coronaGoForced(beacon)
    }

    // MARK: - Network Array Builder

    private func buildNetworkArray(
        _ requests: [[String: Any?]],
        filterAnalytics: Bool
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.reserveCapacity(requests.count)

        for req in requests {
            let url = req["url"] as? String ?? ""

            // Always strip our own beacon-send and config-fetch endpoints.
            if FlutterSendData.isOrionInternalUrl(url) {
                continue
            }

            // Strip third-party analytics URLs only when the filter is on
            // (cf.sa=false, the default). When sa=true, customer has opted
            // in to seeing them and we pass them through.
            if filterAnalytics && FlutterSendData.isAnalyticsUrl(url) {
                continue
            }

            var obj: [String: Any] = [
                "url":        url,
                "method":     req["method"]      as? String ?? "",
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
            out.append(obj)
        }
        return out
    }

    // MARK: - Rage Clicks Array Builder

    /// Rebuilds each rage click for the beacon.
    ///
    /// ⚠️ This is a whitelist: any key not explicitly copied here is dropped.
    /// That is what silently discarded the 1.2.26 scroll-context fields on
    /// iOS while Android forwarded them — the scroll-aware heatmap feature
    /// did not work on iOS at all. When the Dart layer adds a rage click
    /// field, it must be added here too.
    private func buildRageClicksArray(_ clicks: [[String: Any]]) -> [[String: Any]] {
        return clicks.compactMap { click in
            guard
                let x   = (click["x"]     as? NSNumber)?.intValue,
                let y   = (click["y"]     as? NSNumber)?.intValue,
                let cnt = (click["count"] as? NSNumber)?.intValue
            else { return nil }

            var obj: [String: Any] = [
                "x":      x,
                "y":      y,
                "count":  cnt,
                "durMs":  (click["durMs"] as? NSNumber)?.intValue ?? 0,
                "ts":     (click["ts"]    as? NSNumber)?.int64Value ?? 0
            ]

            // Scroll context (1.2.26+): sy = scroll offset at tap time,
            // msy = max scroll extent, cy = content-space Y (y + sy).
            //
            // The Dart tracker emits all three together, and only when the
            // page was actually scrolled (scrollY > 0). This `if let` chain
            // preserves that all-three-or-none contract: an unscrolled tap
            // carries none of them, so the beacon stays byte-identical to
            // pre-1.2.26 for unscrolled pages and the backend never sees a
            // lone `msy` with no position to go with it.
            if let sy  = (click["sy"]  as? NSNumber)?.intValue,
               let msy = (click["msy"] as? NSNumber)?.intValue,
               let cy  = (click["cy"]  as? NSNumber)?.intValue {
                obj["sy"]  = sy
                obj["msy"] = msy
                obj["cy"]  = cy
            }

            return obj
        }
    }
}