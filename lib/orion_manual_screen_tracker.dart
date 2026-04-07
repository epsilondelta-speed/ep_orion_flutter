import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';
import 'orion_frame_metrics.dart';
import 'orion_rage_click_tracker.dart';

/// Manual screen tracker for non-MaterialApp navigation.
///
/// Crash protection: startTracking(), finalizeScreen() and all static methods
/// are wrapped in try-catch so a tracking failure never propagates to the
/// host app's navigation code.
///
/// Dead code removed: _ttfdManual field was set but never read — send() derived
/// the flag from _ttfdSource == 'manual'. Field removed; expression is the
/// single source of truth.
class OrionManualTracker {
  static final Map<String, _ManualScreenMetrics> _screenMetrics = {};
  static final List<String> _screenHistoryStack = [];
  static final Map<String, bool> _manualTTFDFlags = {};

  static void startTracking(String screenName) {
    try {
      if (!OrionFlutter.isSupported) return;
      orionPrint('🚀 [Orion] startTracking() called for: $screenName');

      if (_screenMetrics.containsKey(screenName)) {
        orionPrint('⚠️ [Orion] Already tracking $screenName. Finalizing previous...');
        finalizeScreen(screenName);
      }

      if (_screenHistoryStack.isEmpty || _screenHistoryStack.last != screenName) {
        _screenHistoryStack.add(screenName);
      }

      OrionNetworkTracker.setCurrentScreen(screenName);
      OrionRageClickTracker.setCurrentScreen(screenName);
      OrionFlutter.onFlutterScreenStart(screenName);

      final metrics = _ManualScreenMetrics(screenName);
      _screenMetrics[screenName] = metrics;
      metrics.begin();

      orionPrint('✅ [Orion] Started tracking: $screenName');
    } catch (e) {
      orionPrint('⚠️ OrionManualTracker: startTracking error (ignored): $e');
    }
  }

  static void finalizeScreen(String screenName) {
    try {
      if (!OrionFlutter.isSupported) return;
      orionPrint('🔥 [Orion] finalizeScreen() called for: $screenName');

      final metrics = _screenMetrics.remove(screenName);
      if (_screenHistoryStack.isNotEmpty && _screenHistoryStack.last == screenName) {
        _screenHistoryStack.removeLast();
      }
      _manualTTFDFlags.remove(screenName);
      OrionFlutter.onFlutterScreenStop(screenName);

      if (metrics == null) {
        orionPrint('⚠️ [Orion] No tracking data for $screenName. Skipping send.');
        return;
      }
      metrics.send();
    } catch (e) {
      orionPrint('⚠️ OrionManualTracker: finalizeScreen error (ignored): $e');
    }
  }

  static void resumePreviousScreen() {
    try {
      if (!OrionFlutter.isSupported) return;
      if (_screenHistoryStack.isNotEmpty) {
        final previous = _screenHistoryStack.last;
        orionPrint('🔁 [Orion] Resumed previous screen: $previous');
        startTracking(previous);
      } else {
        orionPrint('⚠️ [Orion] No previous screen to resume');
      }
    } catch (e) {
      orionPrint('⚠️ OrionManualTracker: resumePreviousScreen error: $e');
    }
  }

  static String? getLastTrackedScreen() {
    try {
      if (!OrionFlutter.isSupported) return null;
      if (_screenHistoryStack.length >= 2) {
        return _screenHistoryStack[_screenHistoryStack.length - 2];
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool hasTracked(String screenName) {
    try {
      if (!OrionFlutter.isSupported) return false;
      return _screenMetrics.containsKey(screenName);
    } catch (_) {
      return false;
    }
  }

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

  static String? get currentScreen =>
      _screenHistoryStack.isNotEmpty ? _screenHistoryStack.last : null;

  static void notifyInteraction() {
    try {
      final screen = currentScreen;
      if (screen != null && _screenMetrics.containsKey(screen)) {
        _screenMetrics[screen]?.onUserInteraction();
      }
    } catch (_) {}
  }

  static void onAppWentToBackground() {
    try {
      final screen = currentScreen;
      if (screen != null && _screenMetrics.containsKey(screen)) {
        _screenMetrics[screen]?.onAppBackground();
      }
    } catch (_) {}
  }

  static void onAppCameToForeground() {
    try {
      final screen = currentScreen;
      if (screen != null && _screenMetrics.containsKey(screen)) {
        _screenMetrics[screen]?.onAppForeground();
      }
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class OrionManualInteractionDetector extends StatelessWidget {
  final Widget child;

  const OrionManualInteractionDetector({Key? key, required this.child})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => OrionManualTracker.notifyInteraction(),
      onPointerMove: (_) => OrionManualTracker.notifyInteraction(),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class OrionManualAppLifecycleObserver with WidgetsBindingObserver {
  static OrionManualAppLifecycleObserver? _instance;
  static bool _isInForeground = true;

  OrionManualAppLifecycleObserver._();

  static void initialize() {
    try {
      if (_instance == null) {
        _instance = OrionManualAppLifecycleObserver._();
        WidgetsBinding.instance.addObserver(_instance!);
        orionPrint('🔋 OrionManualAppLifecycleObserver initialized');
        _notifyForegroundAsync();
      }
    } catch (e) {
      orionPrint('⚠️ OrionManualAppLifecycleObserver: initialize error: $e');
    }
  }

  static void _notifyForegroundAsync() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppForeground();
        OrionManualTracker.onAppCameToForeground();
      } catch (_) {}
    });
  }

  static void _notifyBackgroundAsync() {
    Future.microtask(() {
      try {
        OrionFlutter.onAppBackground();
        OrionManualTracker.onAppWentToBackground();
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
      orionPrint('⚠️ OrionManualAppLifecycleObserver: state change error: $e');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ManualScreenMetrics (internal)
// ─────────────────────────────────────────────────────────────────────────────

class _ManualScreenMetrics {
  final String screenName;
  final Stopwatch _stopwatch = Stopwatch();

  int  _ttid         = -1;
  int  _ttfd         = -1;
  bool _ttidCaptured = false;
  bool _ttfdCaptured = false;
  // ✅ Dead field removed: _ttfdManual was set but never read.

  bool   _userInteracted  = false;
  int    _interactionTime = -1;
  String _ttfdSource      = 'unknown';

  bool _wentToBackground = false;
  int  _backgroundCount  = 0;

  int _stableFrameCount = 0;
  static const int _requiredStableFrames = 3;
  static const int _maxFrameDuration     = 16;
  static const int _ttfdTimeoutMs        = 5000;
  int? _lastFrameTime;

  bool _disposed = false;

  _ManualScreenMetrics(this.screenName);

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
      orionPrint('⚠️ _ManualScreenMetrics.begin error: $e');
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
    if (OrionManualTracker._hasManualTTFD(screenName)) {
      _pollForManualTTFD();
    } else {
      SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
    }
  }

  void _pollForManualTTFD() {
    if (_disposed || _ttfdCaptured) return;
    if (OrionManualTracker._hasManualTTFD(screenName)) {
      _ttfd        = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource  = 'manual'; // ✅ single source of truth
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

        // ✅ await so channel exceptions are caught by the surrounding try/catch.
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
        orionPrint('⚠️ _ManualScreenMetrics.send error (ignored): $e');
      }
    });
  }
}
