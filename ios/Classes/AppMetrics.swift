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
///
/// 3. osVersionString / releaseName (1.2.25 fix, previously sdkReleaseName):
///    releaseName was incorrectly set to OrionConfig.sdkVersion. The aggregation
///    pipeline maps releaseName → os in the DB, so it must carry the iOS OS
///    version string (UIDevice.current.systemVersion) to match Android's semantics
///    and keep the `os` field meaningful for version slicing in dashboards.
///    libVer (set by SendData.appendCommonFields) remains the correct carrier
///    for the SDK version. The two must NOT share the same source.
///
/// 4. IOS-02 (1.2.32): no filesystem syscalls on the beacon path.
///    getAppMetrics() ran SEVEN of them on the main thread for every screen
///    beacon — six stat() calls from the jailbreak probe plus one statfs() for
///    disk usage — because handleTrackScreen arrives on the Flutter platform
///    thread, which on iOS is the main thread. Both values are now cached:
///    jailbreak status once per process (it cannot change), disk usage behind
///    a 60 s TTL refreshed off the main thread. warmCaches() populates both on
///    a background queue at plugin init, so the beacon path reads memory only.
///    hashedDeviceId() is memoised for the same reason — not a syscall, but
///    per-beacon work on a value that is constant for the install.
final class AppMetrics {

    // MARK: - Singleton
    static let shared = AppMetrics()
    private init() {}

    // MARK: - Config

    var companyId:  String = ""
    var projectId:  String = ""
    var appVersion: String = ""

    /// iOS OS version string reported in the `releaseName` field.
    ///
    /// The aggregation pipeline maps `releaseName` → `os` in the database,
    /// so this must be the device OS version (e.g. "17.5.1"), NOT the SDK
    /// version. On Android, `releaseName` carries the Android OS version
    /// ("13", "14", etc.); iOS must match that semantics for cross-platform
    /// `os` field consistency.
    ///
    /// Note: `libVer` (set by SendData.appendCommonFields) is the separate
    /// field that carries the SDK version. The two must NOT be the same source.
    ///
    /// 1.2.25 fix: previously this was set to OrionConfig.sdkVersion, which
    /// caused the aggregation pipeline to write the SDK version string into
    /// the `os` DB field, breaking iOS version slicing in dashboards.
    ///
    /// IOS-03: served from the main-thread snapshot, never from UIKit on the
    /// caller's thread. The fallback is ProcessInfo, which reports the same
    /// version and is safe from any thread — so even the pre-init path never
    /// touches UIDevice off the main thread.
    var osVersionString: String {
        factLock.lock()
        let snapshot = systemVersionSnapshot
        factLock.unlock()
        if !snapshot.isEmpty { return snapshot }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Major OS version. Reads ProcessInfo rather than UIDevice — same number,
    /// no UIKit, safe from any thread.
    private var iOSVersion: Int {
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    // MARK: - Full App Metrics (for beacon merging)

    func getAppMetrics() -> [String: Any] {
        // IOS-03: UIScreen is only touched when we are already on the main
        // thread. Doing so keeps the live behaviour callers had before —
        // rotation is reflected immediately on the screen-beacon path, which
        // always arrives on the main thread — while off-main callers (the
        // uncaught-exception handler, MetricKit's delivery queue) read the
        // last captured snapshot instead of touching UIKit illegally.
        if Thread.isMainThread {
            let fresh = AppMetrics.readDisplay()
            factLock.lock()
            displaySnapshot = fresh
            factLock.unlock()
        }

        factLock.lock()
        let display = displaySnapshot
        factLock.unlock()

        let deviceWidthPx  = display?.deviceWidthPx  ?? 0
        let deviceHeightPx = display?.deviceHeightPx ?? 0

        // A nil snapshot means a beacon was assembled before
        // prepareOnMainThread() ran, which cannot happen after plugin init —
        // beacons require a tracked screen, and init completes first. Zeros
        // are emitted rather than blocking: hopping to the main thread here
        // would deadlock the crash handler, which is precisely the caller
        // this fix exists to protect.
        let deviceDimensions: [String: Any] = [
            "deviceWidth":    deviceWidthPx,
            "deviceHeight":   deviceHeightPx,
            "viewportWidth":  display?.viewportWidth  ?? 0,
            "viewportHeight": display?.viewportHeight ?? 0,
            "densityDpi":     display?.densityDpi     ?? 0,
            "density":        display?.density        ?? 0
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
            "releaseName":      osVersionString,

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

    /// IOS-05: the hardware identifier is fixed at boot, so `uname()` ran once
    /// per beacon for a constant. `lazy` resolves it on first use and never
    /// again. (`lazy var` on a singleton reached from several threads is only
    /// safe because the first read happens during init, on the main thread —
    /// prepareOnMainThread() forces it, so no beacon path can race it.)
    private lazy var cachedDeviceModel: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return AppMetrics.marketingNames[machine] ?? machine
    }()

    private lazy var cachedBundleId: String = Bundle.main.bundleIdentifier ?? "unknown"

    private func deviceModel() -> String { return cachedDeviceModel }

    private func bundleId() -> String { return cachedBundleId }

    /// IOS-05: `static let`, not a dictionary literal rebuilt on every lookup.
    /// Fifteen entries were allocated per beacon to answer one subscript.
    private static let marketingNames: [String: String] = [
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

    // MARK: - Hashed Device ID

    private func hashedDeviceId() -> String {
        // In-memory cache in front of UserDefaults. The stored value is
        // constant for the install, so re-reading it on every beacon bought
        // nothing. UserDefaults reads are served from memory rather than disk,
        // so this was never one of the seven syscalls — it is simply work the
        // main thread no longer has to do per beacon.
        factLock.lock()
        let memo   = hashedDeviceIdCache
        let vendor = vendorIdSnapshot
        factLock.unlock()
        if let memo = memo { return memo }

        let key = "orion_hashed_device_id"
        let value: String
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            value = stored
        } else {
            // IOS-03: identifierForVendor is UIDevice, captured on the main
            // thread by prepareOnMainThread(). Reading it here would put a
            // UIKit call on the crash handler's thread. The UUID fallback is
            // the pre-existing behaviour for a nil vendor id; it is persisted
            // below, so it stays stable for the install either way.
            let rawId = vendor ?? UUID().uuidString
            value = sha256(rawId)
            UserDefaults.standard.set(value, forKey: key)
        }

        factLock.lock()
        hashedDeviceIdCache = value
        factLock.unlock()
        return value
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cached device facts (IOS-02)
    //
    // Through 1.2.31, getAppMetrics() performed SEVEN filesystem syscalls on
    // the main thread for every single screen beacon: six stat() calls from
    // the jailbreak probe (all six run on a healthy device — `contains` only
    // short-circuits on a hit, which is the jailbroken case) plus one statfs()
    // for disk usage.
    //
    // That is real main-thread time on a path the host app cannot see or
    // avoid, repeated on every screen transition, and it is entirely
    // avoidable: a device does not become jailbroken mid-session, and disk
    // usage does not meaningfully move between two screen transitions a few
    // seconds apart.
    //
    // Both values are now cached. The jailbreak answer is computed once per
    // process; disk usage is refreshed at most once a minute, off the main
    // thread, and the beacon path always reads memory.

    /// Guards the cached facts below. Held only across memory reads/writes —
    /// never across the filesystem probes themselves.
    private let factLock = NSLock()

    private var jailbrokenCache:     Bool?
    private var hashedDeviceIdCache: String?

    // MARK: - UIKit snapshot (IOS-03)
    //
    // UIScreen and UIDevice are main-thread-only APIs. getAppMetrics() read
    // them directly, and three of its callers are not on the main thread:
    //
    //   * the NSSetUncaughtExceptionHandler closure, which runs on whatever
    //     thread threw, during termination — the worst possible place to
    //     touch UIKit. UIScreen.main can take internal locks and force
    //     layout; if the crashing thread already held one, the handler hangs
    //     and the crash beacon is never persisted. 1.2.27 moved crash
    //     delivery to disk and 1.2.31 made the health read lock-free, both to
    //     stop exactly this class of loss — while this call sat in the same
    //     handler doing the same thing.
    //   * OrionMetricKitCollector.buildBeacon(), on its private utility queue.
    //   * anything reaching AppMetrics.shared before plugin init.
    //
    // The values are now captured on the main thread and served from memory.

    private struct DisplaySnapshot {
        let deviceWidthPx:  Int
        let deviceHeightPx: Int
        let viewportWidth:  CGFloat
        let viewportHeight: CGFloat
        let densityDpi:     Int
        let density:        Double
    }

    private var displaySnapshot:       DisplaySnapshot?
    private var systemVersionSnapshot: String  = ""
    private var vendorIdSnapshot:      String?
    private var resizeObserver:        NSObjectProtocol?

    private var diskUsageCache:      Int = -1
    private var diskUsageStamp:      TimeInterval = 0
    private var diskRefreshInFlight: Bool = false
    private let diskCacheTTL:        TimeInterval = 60

    /// Populate both caches off the main thread, before the first beacon needs
    /// them. Called once from plugin initialize().
    ///
    /// Without this the first beacon of the process would still pay for the
    /// probes on whatever thread it runs on. With it, the values are almost
    /// always already resident by the time the first screen is tracked, and
    /// the synchronous fallbacks below exist only for the race.
    func warmCaches() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            _ = self.isDeviceJailbroken()
            self.refreshDiskUsage()
            // Safe off-main now that prepareOnMainThread() has captured the
            // vendor id: what remains here is the UserDefaults read (which can
            // hit disk on first access) and the SHA-256, neither of which is
            // UIKit. Must run after prepare — plugin init guarantees that.
            _ = self.hashedDeviceId()
        }
    }

    // MARK: - Main-thread capture (IOS-03)

    /// Capture every main-thread-only UIKit value into the snapshot.
    ///
    /// Called from plugin init, which runs on the Flutter platform thread —
    /// the main thread on iOS — and again whenever the app becomes active, so
    /// a rotation or iPad split-view resize that happened while the app was
    /// away is reflected for off-main readers.
    func prepareOnMainThread() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.prepareOnMainThread() }
            return
        }

        let version  = UIDevice.current.systemVersion
        let vendorId = UIDevice.current.identifierForVendor?.uuidString
        let display  = AppMetrics.readDisplay()

        // IOS-05: force the lazy constants here, on the main thread, before any
        // beacon can reach them. `lazy var` is NOT thread-safe in Swift — two
        // concurrent first-accesses race on the backing storage — and
        // getAppMetrics() is reachable from the crash handler and MetricKit's
        // queue. Resolving them on this known-single-threaded path removes the
        // race rather than relying on beacons never overlapping.
        _ = cachedDeviceModel
        _ = cachedBundleId

        factLock.lock()
        systemVersionSnapshot = version
        displaySnapshot       = display
        // Captured once. Re-reading on every activation would be harmless but
        // pointless — identifierForVendor is stable for the install.
        if vendorIdSnapshot == nil { vendorIdSnapshot = vendorId }
        factLock.unlock()

        guard resizeObserver == nil else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let display = AppMetrics.readDisplay()
            self.factLock.lock()
            self.displaySnapshot = display
            self.factLock.unlock()
        }
    }

    /// Reads UIScreen. MUST be called on the main thread.
    private static func readDisplay() -> DisplaySnapshot {
        let screen       = UIScreen.main
        let bounds       = screen.bounds
        let scale        = screen.scale
        let nativeBounds = screen.nativeBounds

        return DisplaySnapshot(
            deviceWidthPx:  Int(nativeBounds.width),
            deviceHeightPx: Int(nativeBounds.height),
            viewportWidth:  bounds.width,
            viewportHeight: bounds.height,
            densityDpi:     Int(scale * 160),
            density:        Double(scale)
        )
    }

    // MARK: - Jailbreak Detection

    /// Constant for the lifetime of the process — computed once, then free.
    private func isDeviceJailbroken() -> Bool {
        factLock.lock()
        let cached = jailbrokenCache
        factLock.unlock()
        if let cached = cached { return cached }

        // Probed outside the lock. Two threads racing here both do the work
        // and write the same answer, which is cheaper and safer than holding
        // a lock across six syscalls.
        let value = probeJailbreak()

        factLock.lock()
        jailbrokenCache = value
        factLock.unlock()
        return value
    }

    private func probeJailbreak() -> Bool {
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
        //
        // IOS-05: this used to read the value out of getSessionMetrics(),
        // which builds a twelve-key dictionary — six derived durations and six
        // String(format:) calls — and then threw eleven of the twelve away.
        // FlutterSendData calls getSessionMetrics() for the beacon two lines
        // before it calls this, so that whole dictionary was built twice per
        // beacon on the main thread to obtain one Int.
        return BatteryMetricsTracker.shared.currentBatteryLevel()
    }

    // MARK: - Disk % (cached; safe from any thread)

    /// Serves the cached disk usage, never blocking the caller on a syscall
    /// once the cache is warm.
    ///
    /// A stale value is returned immediately and refreshed in the background,
    /// rather than made the caller's problem. Disk usage is a slow-moving
    /// percentage of total capacity — a value up to a minute old is
    /// indistinguishable from a fresh one at this resolution, and the beacon
    /// reports it as a whole-number percent.
    private func diskUsagePercent() -> Int {
        let now = ProcessInfo.processInfo.systemUptime

        factLock.lock()
        let cached    = diskUsageCache
        let stamp     = diskUsageStamp
        let hasValue  = stamp > 0
        let isFresh   = hasValue && (now - stamp) < diskCacheTTL
        var shouldRefresh = false
        if hasValue && !isFresh && !diskRefreshInFlight {
            diskRefreshInFlight = true
            shouldRefresh = true
        }
        factLock.unlock()

        if isFresh { return cached }

        if hasValue {
            // Stale — hand back the last known value now, refresh off-thread.
            if shouldRefresh {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.refreshDiskUsage()
                }
            }
            return cached
        }

        // No value yet. warmCaches() normally wins this race; if it has not,
        // pay for exactly one statfs() rather than emit the -1 error sentinel
        // into real data.
        return refreshDiskUsage()
    }

    /// Performs the statfs() and stores the result. Safe to call from any
    /// thread; intended to be called off the main one.
    @discardableResult
    private func refreshDiskUsage() -> Int {
        let value = probeDiskUsage()
        let now   = ProcessInfo.processInfo.systemUptime

        factLock.lock()
        // A failed probe must not overwrite a good reading with -1, and must
        // not stamp the cache fresh — otherwise one transient failure would
        // pin the beacon to -1 for a full TTL.
        if value >= 0 {
            diskUsageCache = value
            diskUsageStamp = now
        }
        diskRefreshInFlight = false
        factLock.unlock()
        return value
    }

    private func probeDiskUsage() -> Int {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let total = attrs[.systemSize]     as? Int64,
            let free  = attrs[.systemFreeSize] as? Int64,
            total > 0
        else { return -1 }
        return Int((Double(total - free) / Double(total)) * 100)
    }
}