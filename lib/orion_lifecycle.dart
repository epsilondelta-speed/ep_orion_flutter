import 'package:flutter/widgets.dart';

import 'orion_flutter.dart';
import 'orion_logger.dart';
import 'orion_manual_screen_tracker.dart';
import 'orion_sampling_manager.dart';
import 'orion_screen_tracker.dart';

/// The SDK's single app-lifecycle observer (1.2.36).
///
/// WHY THIS EXISTS
///
/// Until 1.2.36 the SDK shipped two lifecycle observers and registered neither.
/// The host had to call `OrionAppLifecycleObserver.initialize()` or
/// `OrionManualAppLifecycleObserver.initialize()` itself, and a customer that
/// called neither lost, silently:
///
///   * per-foreground battery session re-evaluation. The native
///     ActivityLifecycleCallbacks calls BatteryMetricsTracker.onAppForegrounded
///     only once, guarded by `batterySessionStarted`, so every foreground after
///     the first reaches the tracker ONLY through this observer. Without it
///     `isInForeground` and `lastForegroundTime` go stale after the first
///     background and foreground-duration accounting drifts.
///   * start-type re-classification. `StartTypeTracker.initialize()` re-runs on
///     the native side of onAppForeground (1.2.26); without it getStartType()
///     keeps reporting "cold" for the life of the process.
///   * wake-lock foreground tracking.
///   * CDN config refresh pausing. `SamplingManager.pauseRefresh()` had exactly
///     ONE caller — the auto observer — so a host registering nothing kept the
///     config timer polling while backgrounded, which is pure network and radio
///     cost for a beacon path that only assembles in the foreground.
///
/// The two observers were also not equivalent: only the auto one paused the
/// config refresh, and each notified just its own screen tracker. Which one a
/// host picked silently changed what the SDK collected.
///
/// WHAT THIS DOES
///
/// One observer, registered once, doing the union of the two. Both public
/// classes now delegate here, and `initializeEdOrion` registers it, so it does
/// not matter whether the host calls one, the other, both, or nothing — exactly
/// one observer is ever attached and it always does the full job. That is what
/// rules out the double-fire that auto-registering alongside a host's own
/// explicit call would otherwise cause.
///
/// Each notification is guarded independently. A single try/catch around the
/// group (which is what the old observers had) meant a throw in
/// `OrionFlutter.onAppForeground()` silently skipped the config resume too.
class OrionLifecycle with WidgetsBindingObserver {
  OrionLifecycle._();

  static OrionLifecycle? _instance;
  static bool _isInForeground = true;

  static bool get isRegistered => _instance != null;
  static bool get isInForeground => _isInForeground;

  /// Attaches the observer if it is not already attached.
  ///
  /// Throws if the Flutter binding is not up yet — callers decide whether to
  /// retry. [OrionFlutter.initializeEdOrion] does; see its comment for why a
  /// silent skip is the wrong behaviour for this particular feature.
  static void ensureRegistered() {
    if (_instance != null) return;
    final observer = OrionLifecycle._();
    WidgetsBinding.instance.addObserver(observer);
    _instance = observer;
    orionPrint('🔋 [Orion] Lifecycle observer registered');
    _notifyForeground();
  }

  static void dispose() {
    try {
      final observer = _instance;
      if (observer != null) {
        WidgetsBinding.instance.removeObserver(observer);
        _instance = null;
      }
    } catch (_) {}
  }

  static void _notifyForeground() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppForeground();
      } catch (_) {}
      try {
        OrionScreenTracker.onAppCameToForeground();
      } catch (_) {}
      try {
        OrionManualTracker.onAppCameToForeground();
      } catch (_) {}
      try {
        // Restart CDN config polling — see SamplingManager.pauseRefresh().
        SamplingManager.instance.resumeRefresh();
      } catch (_) {}
    });
  }

  static void _notifyBackground() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppBackground();
      } catch (_) {}
      try {
        OrionScreenTracker.onAppWentToBackground();
      } catch (_) {}
      try {
        OrionManualTracker.onAppWentToBackground();
      } catch (_) {}
      try {
        // Beacons are only assembled in the foreground, so polling the config
        // while backgrounded is pure network and radio cost.
        SamplingManager.instance.pauseRefresh();
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      switch (state) {
        case AppLifecycleState.resumed:
          if (!_isInForeground) {
            _isInForeground = true;
            orionPrint('🔋 App resumed (foreground)');
            _notifyForeground();
          }
          break;
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
        case AppLifecycleState.detached:
        case AppLifecycleState.hidden:
          if (_isInForeground) {
            _isInForeground = false;
            orionPrint('🔋 App paused (background)');
            _notifyBackground();
          }
          break;
      }
    } catch (e) {
      orionPrint('⚠️ OrionLifecycle: state change error: $e');
    }
  }
}
