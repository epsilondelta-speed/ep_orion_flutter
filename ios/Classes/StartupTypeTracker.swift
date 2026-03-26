import Foundation
import UIKit

/// StartupTypeTracker — Detects app startup type.
/// Mirrors StartTypeTracker in Android Kotlin.
///
/// Android:
///   cold = fresh process, no saved state
///   warm = process killed by OS, relaunched
///   hot  = resumed from background (process alive)
///
/// iOS equivalent:
///   cold = app was not in memory at all (first launch or killed)
///   warm = app was suspended and relaunched after long gap
///   hot  = app resumed from background within short gap
///
/// Detection strategy:
///   Store exit timestamp in UserDefaults on background.
///   On next foreground, compare gap:
///     gap == nil (first ever launch)     → cold
///     gap > 30 seconds                   → cold  (process was killed)
///     gap > 5 seconds && <= 30 seconds   → warm
///     gap <= 5 seconds                   → hot
final class StartupTypeTracker {

    // MARK: - Singleton
    static let shared = StartupTypeTracker()
    private init() {}

    // MARK: - Constants
    private let exitTimestampKey  = "orion_last_exit_timestamp"
    private let coldThresholdSec: TimeInterval = 30.0
    private let warmThresholdSec: TimeInterval = 5.0

    // MARK: - State
    private var startupType: String = "cold"
    private var isDetected:  Bool   = false

    // MARK: - Detect on init

    func detectStartupType() {
        guard !isDetected else { return }
        isDetected = true

        let defaults = UserDefaults.standard
        let lastExit = defaults.double(forKey: exitTimestampKey)

        if lastExit <= 0 {
            // First ever launch — cold start
            startupType = "cold"
            OrionLogger.debug("StartupTypeTracker: COLD (first launch)")
        } else {
            let gap = Date().timeIntervalSince1970 - lastExit
            if gap > coldThresholdSec {
                startupType = "cold"
                OrionLogger.debug("StartupTypeTracker: COLD (gap: \(Int(gap))s > \(Int(coldThresholdSec))s)")
            } else if gap > warmThresholdSec {
                startupType = "warm"
                OrionLogger.debug("StartupTypeTracker: WARM (gap: \(Int(gap))s)")
            } else {
                startupType = "hot"
                OrionLogger.debug("StartupTypeTracker: HOT (gap: \(Int(gap * 1000))ms)")
            }
        }
    }

    /// Save exit timestamp when app goes to background.
    /// Called from applicationDidEnterBackground.
    func saveExitTimestamp() {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: exitTimestampKey
        )
        // Reset for next launch detection
        isDetected = false
        OrionLogger.debug("StartupTypeTracker: Exit timestamp saved")
    }

    /// Returns "cold", "warm", or "hot" — same values as Android
    func getStartupType() -> String {
        if !isDetected { detectStartupType() }
        return startupType
    }
}
