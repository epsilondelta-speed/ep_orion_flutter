import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';
import 'orion_frame_metrics.dart';
import 'orion_rage_click_tracker.dart';
import 'orion_sampling_manager.dart';

/// RouteObserver with comprehensive frame tracking and interaction-aware TTFD.
///
/// Crash protection: all RouteObserver overrides are wrapped in try-catch so a
/// tracking failure can never propagate to the Navigator and disrupt navigation.
///
/// Dead code removed: _ttfdManual field was set in _pollForManualTTFD() but
/// never read — send() derived the same value from _ttfdSource == 'manual'.
/// Removed the field; the derived expression is the single source of truth.
///
/// Leak fix (Fix #10): _startTracking() previously overwrote any existing
/// _ScreenMetrics for the same screen name without finalising it. The orphan
/// kept its frame callback chain alive (re-scheduling itself via
/// SchedulerBinding.scheduleFrameCallback) and its Stopwatch running, leaking
/// resources for the rest of the app's lifetime. Now we mirror the pattern in
/// OrionManualTracker.startTracking and finalise the previous tracker first.
///
/// Why send() uses Future.delayed and NOT addPostFrameCallback:
/// I tried switching to WidgetsBinding.instance.addPostFrameCallback to avoid
/// the arbitrary 100ms wait, but addPostFrameCallback only fires when a frame
/// is drawn. If the app is backgrounded (or transitioning) when send() is
/// called, the callback queues up indefinitely and fires all-at-once when the
/// app foregrounds — which can compound with other deferred work and cause
/// input-dispatch ANRs. Future.delayed is independent of frame scheduling, so
/// it fires reliably even during lifecycle transitions. We accept the tradeoff
/// that a process kill within 100ms of leaving a screen drops that beacon —
/// rare in practice and safer than the alternative.
class OrionScreenTracker extends RouteObserver<PageRoute<dynamic>> {
  final Map<String, _ScreenMetrics> _screenMetrics = {};

  static final Map<String, bool> _manualTTFDFlags = {};
  static OrionScreenTracker? _instance;
  String? _currentScreenName;

  OrionScreenTracker() {
    _instance = this;
  }

  static OrionScreenTracker? get instance => _instance;

  // ── RouteObserver overrides — all guarded ─────────────────────────────────

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    try {
      if (!OrionFlutter.isSupported) return;
      _finalizeTracking(previousRoute);
      _updateCurrentScreen(route);
      _startTracking(route);
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: didPush error (ignored): $e');
    }
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    try {
      if (!OrionFlutter.isSupported) return;
      _finalizeTracking(oldRoute);
      _updateCurrentScreen(newRoute);
      _startTracking(newRoute);
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: didReplace error (ignored): $e');
    }
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    try {
      if (!OrionFlutter.isSupported) return;
      _finalizeTracking(route);
      _updateCurrentScreen(previousRoute);
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: didPop error (ignored): $e');
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _updateCurrentScreen(Route? route) {
    try {
      if (route is PageRoute) {
        final screenName = route.settings.name ?? route.runtimeType.toString();
        _currentScreenName = screenName;
        OrionNetworkTracker.setCurrentScreen(screenName);
        OrionRageClickTracker.setCurrentScreen(screenName);
        orionPrint('📍 OrionScreenTracker: currentScreenName = $screenName');
      }
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: _updateCurrentScreen error: $e');
    }
  }

  void _startTracking(Route? route) {
    try {
      if (route is PageRoute) {
        final screenName = route.settings.name ?? route.runtimeType.toString();

        // ✅ Fix #10: finalise any existing tracker for the same screen name
        //    before starting a new one. Without this, the previous tracker is
        //    silently overwritten — its Stopwatch keeps running and its frame
        //    callback keeps re-scheduling itself via scheduleFrameCallback,
        //    leaking resources for the lifetime of the app.
        //
        //    Real-world trigger: nested navigation that pushes the same named
        //    route twice without a pop in between (rare but happens with
        //    bottom-nav apps that allow stacking duplicate screens).
        if (_screenMetrics.containsKey(screenName)) {
          orionPrint(
            '⚠️ OrionScreenTracker: already tracking $screenName, '
                'finalising previous tracker before starting new one',
          );
          final previous = _screenMetrics.remove(screenName);
          previous?.send();
        }

        final metrics = _ScreenMetrics(screenName);
        _screenMetrics[screenName] = metrics;
        metrics.begin();
        OrionFlutter.onFlutterScreenStart(screenName);
      }
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: _startTracking error: $e');
    }
  }

  void _finalizeTracking(Route? route) {
    try {
      if (route is PageRoute) {
        final screenName = route.settings.name ?? route.runtimeType.toString();
        final metrics = _screenMetrics.remove(screenName);
        OrionFlutter.onFlutterScreenStop(screenName);
        metrics?.send();
        _manualTTFDFlags.remove(screenName);
      }
    } catch (e) {
      orionPrint('⚠️ OrionScreenTracker: _finalizeTracking error: $e');
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  static void markFullyDrawn(String screenName) {
    try {
      if (!OrionFlutter.isSupported) return;
      _manualTTFDFlags[screenName] = true;
      orionPrint('🎯 [$screenName] Manual TTFD triggered');
    } catch (_) {}
  }

  static bool _hasManualTTFD(String screenName) {
    return _manualTTFDFlags[screenName] == true;
  }

  void notifyInteraction() {
    try {
      if (_currentScreenName != null &&
          _screenMetrics.containsKey(_currentScreenName)) {
        _screenMetrics[_currentScreenName]?.onUserInteraction();
      }
    } catch (_) {}
  }

  static void onInteraction() {
    try { _instance?.notifyInteraction(); } catch (_) {}
  }

  static void onAppWentToBackground() {
    try {
      if (_instance?._currentScreenName != null) {
        _instance?._screenMetrics[_instance!._currentScreenName]
            ?.onAppBackground();
      }
    } catch (_) {}
  }

  static void onAppCameToForeground() {
    try {
      if (_instance?._currentScreenName != null) {
        _instance?._screenMetrics[_instance!._currentScreenName]
            ?.onAppForeground();
      }
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OrionInteractionDetector
// ─────────────────────────────────────────────────────────────────────────────

class OrionInteractionDetector extends StatelessWidget {
  final Widget child;

  const OrionInteractionDetector({Key? key, required this.child})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => OrionScreenTracker.onInteraction(),
      onPointerMove: (_) => OrionScreenTracker.onInteraction(),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OrionAppLifecycleObserver
// ─────────────────────────────────────────────────────────────────────────────

class OrionAppLifecycleObserver with WidgetsBindingObserver {
  static OrionAppLifecycleObserver? _instance;
  static bool _isInForeground = true;

  OrionAppLifecycleObserver._();

  static void initialize() {
    try {
      if (_instance == null) {
        _instance = OrionAppLifecycleObserver._();
        WidgetsBinding.instance.addObserver(_instance!);
        orionPrint('🔋 OrionAppLifecycleObserver initialized');
        _notifyForegroundAsync();
      }
    } catch (e) {
      orionPrint('⚠️ OrionAppLifecycleObserver: initialize error: $e');
    }
  }

  static void _notifyForegroundAsync() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppForeground();
        OrionScreenTracker.onAppCameToForeground();
      } catch (_) {}
    });
  }

  static void _notifyBackgroundAsync() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppBackground();
        OrionScreenTracker.onAppWentToBackground();
      } catch (_) {}
    });
  }

  static void dispose() {
    try {
      if (_instance != null) {
        WidgetsBinding.instance.removeObserver(_instance!);
        _instance = null;
      }
    } catch (_) {}
  }

  static bool get isInForeground => _isInForeground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      switch (state) {
        case AppLifecycleState.resumed:
          if (!_isInForeground) {
            _isInForeground = true;
            orionPrint('🔋 App resumed (foreground)');
            _notifyForegroundAsync();
          }
          break;
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
          if (_isInForeground) {
            _isInForeground = false;
            orionPrint('🔋 App paused (background)');
            _notifyBackgroundAsync();
          }
          break;
        case AppLifecycleState.detached:
        case AppLifecycleState.hidden:
          if (_isInForeground) {
            _isInForeground = false;
            _notifyBackgroundAsync();
          }
          break;
      }
    } catch (e) {
      orionPrint('⚠️ OrionAppLifecycleObserver: state change error: $e');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScreenMetrics (internal)
// ─────────────────────────────────────────────────────────────────────────────

class _ScreenMetrics {
  final String screenName;
  final Stopwatch _stopwatch = Stopwatch();

  int  _ttid          = -1;
  int  _ttfd          = -1;
  bool _ttidCaptured  = false;
  bool _ttfdCaptured  = false;
  // ✅ Dead field removed: _ttfdManual was set but never read.
  //    send() derives the value from _ttfdSource == 'manual' directly.

  bool   _userInteracted  = false;
  int    _interactionTime = -1;
  String _ttfdSource      = 'unknown';

  bool _wentToBackground = false;
  int  _backgroundCount  = 0;

  int _stableFrameCount = 0;
  static const int    _requiredStableFrames = 3;
  static const int    _maxFrameDuration     = 16;
  static const int    _ttfdTimeoutMs        = 5000;
  int? _lastFrameTime;

  bool _disposed = false;

  _ScreenMetrics(this.screenName);

  void begin() {
    try {
      if (!OrionFlutter.isSupported) return;
      _stopwatch.start();
      _wentToBackground = false;
      _backgroundCount  = 0;
      _captureTTID();
      _startTTFDTracking();
      OrionFrameMetrics.startTracking(screenName);
    } catch (e) {
      orionPrint('⚠️ _ScreenMetrics.begin error: $e');
    }
  }

  void onAppBackground() {
    if (_disposed) return;
    _wentToBackground = true;
    _backgroundCount++;
    orionPrint('📱 [$screenName] App went to background (count: $_backgroundCount)');
  }

  void onAppForeground() {
    if (_disposed) return;
    orionPrint('📱 [$screenName] App came to foreground');
  }

  void onUserInteraction() {
    if (_userInteracted || _ttfdCaptured || _disposed) return;
    _userInteracted  = true;
    _interactionTime = _stopwatch.elapsedMilliseconds;
    orionPrint('👆 [$screenName] Interaction at $_interactionTime ms');
    if (!_ttfdCaptured) {
      _ttfd        = _interactionTime;
      _ttfdCaptured = true;
      _ttfdSource  = 'interaction';
      orionPrint('✅ [$screenName] TTFD (interaction): $_ttfd ms');
    }
  }

  void _captureTTID() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _ttidCaptured) return;
      _ttid        = _stopwatch.elapsedMilliseconds;
      _ttidCaptured = true;
      orionPrint('🎨 [$screenName] TTID: $_ttid ms');
    });
  }

  void _startTTFDTracking() {
    if (OrionScreenTracker._hasManualTTFD(screenName)) {
      _startManualTTFDTracking();
    } else {
      SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
    }
  }

  void _startManualTTFDTracking() {
    orionPrint('⏳ [$screenName] Waiting for manual TTFD trigger...');
    _pollForManualTTFD();
  }

  void _pollForManualTTFD() {
    if (_disposed || _ttfdCaptured) return;
    if (OrionScreenTracker._hasManualTTFD(screenName)) {
      _ttfd        = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource  = 'manual';      // ✅ single source of truth
      orionPrint('✅ [$screenName] Manual TTFD captured: $_ttfd ms');
      return;
    }
    if (_stopwatch.elapsedMilliseconds > _ttfdTimeoutMs) {
      _ttfd        = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource  = 'timeout';
      orionPrint('⚠️ [$screenName] Manual TTFD timeout: $_ttfd ms');
      return;
    }
    Future.delayed(const Duration(milliseconds: 50), _pollForManualTTFD);
  }

  void _onFrame(Duration timestamp) {
    if (_disposed || _ttfdCaptured) return;
    final currentTime = timestamp.inMilliseconds;

    if (_stopwatch.elapsedMilliseconds > _ttfdTimeoutMs) {
      _ttfd        = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource  = 'timeout';
      orionPrint('⚠️ [$screenName] TTFD timeout: $_ttfd ms');
      return;
    }

    if (_lastFrameTime != null) {
      final frameDuration = currentTime - _lastFrameTime!;
      if (frameDuration <= _maxFrameDuration) {
        _stableFrameCount++;
        if (_stableFrameCount >= _requiredStableFrames) {
          _ttfd        = _stopwatch.elapsedMilliseconds;
          _ttfdCaptured = true;
          _ttfdSource  = 'stable_frames';
          orionPrint('✅ [$screenName] TTFD (stable): $_ttfd ms');
          return;
        }
      } else {
        if (frameDuration > 32) _stableFrameCount = 0;
      }
    }

    _lastFrameTime = currentTime;
    if (!_ttfdCaptured) {
      SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
    }
  }

  void send() {
    if (!OrionFlutter.isSupported || _disposed) return;
    _disposed = true;

    // ⚠️ Reverted from addPostFrameCallback back to Future.delayed.
    //    addPostFrameCallback only fires when a frame is drawn — if the app
    //    is backgrounded or transitioning when send() is called, the callback
    //    queues up and fires all at once on the next frame. Combined with
    //    Fix #10's "finalise previous before starting new" logic, this can
    //    pile multiple awaited platform channel calls onto one frame and
    //    contribute to input-dispatch ANRs.
    //
    //    Future.delayed fires from the event loop independent of frame
    //    scheduling, so it works reliably during lifecycle transitions.
    //    Tradeoff: 100ms after-the-fact wait that can be lost on process
    //    kill — acceptable, since the original code shipped this way.
    Future.delayed(const Duration(milliseconds: 100), () async {
      try {
        if (!OrionFlutter.isSupported) return;

        if (!_ttfdCaptured) {
          _ttfd        = _stopwatch.elapsedMilliseconds;
          _ttfdCaptured = true;
          _ttfdSource  = 'finalize';
        }

        final frameMetrics   = OrionFrameMetrics.stopTracking(screenName);
        final networkData    = OrionNetworkTracker.consumeRequestsForScreen(screenName);
        final rageClicks     = OrionRageClickTracker.getRageClicksJson(screenName);
        final rageClickCount = OrionRageClickTracker.getRageClickCount(screenName);
        OrionRageClickTracker.clearScreen(screenName);

        orionPrint(
          '📤 [$screenName] Sending beacon — '
              'TTID: $_ttid ms, TTFD: $_ttfd ms (source: $_ttfdSource), '
              'Network: ${networkData.length}, RageClicks: $rageClickCount',
        );

        final frameBeacon = frameMetrics.toBeacon();
        frameBeacon['ttfdSrc'] = _ttfdSource;
        if (_userInteracted) frameBeacon['intTime'] = _interactionTime;

        await OrionFlutter.trackFlutterScreen(
          screen:         screenName,
          ttid:           _ttid,
          ttfd:           _ttfd,
          ttfdManual:     _ttfdSource == 'manual', // ✅ derived, not stored field
          jankyFrames:    frameMetrics.jankyFrames,
          frozenFrames:   frameMetrics.frozenFrames,
          network:        networkData,
          frameMetrics:   frameBeacon,
          wentBg:         _wentToBackground,
          bgCount:        _backgroundCount,
          rageClicks:     rageClicks,
          rageClickCount: rageClickCount,
        );
      } catch (e) {
        orionPrint('⚠️ _ScreenMetrics.send error (ignored): $e');
      }
    });
  }
}