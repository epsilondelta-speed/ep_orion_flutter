## 1.2.15

### Added
- confOriSamplV2 sampling configuration schema (s, sa, crm, cv fields)
- cf field attached to every beacon (resolved sampling state snapshot)
- EdOrion.disable() / EdOrion.enable() runtime kill switch

### Fixed (Android)
- Main-thread crash beacons no longer dropped due to NetworkOnMainThreadException
- Phase-tracked diagnostic logger in AppCrashAnalyzer
- Four-layer crash handler defense in EdOrion
- @Volatile currentActivity for safe cross-thread reads from crash handler
- BatteryMetricsTracker switched to BroadcastReceiver-based design (no per-call IPC)
- SessionManager uses in-memory cache + throttled disk writes
- WakeLockTracker caps tracked tags at 50 with LRU eviction
- ANRMonitor uses lazy lineSequence (saves ~80KB GC per ANR)
- Native-side analytics URL filtering in FlutterSendData

### Fixed (iOS)
- releaseName now matches libVer (was hardcoded to 1.0.8)
- WakeLockTracker reports correct maxMs for currently-held locks
