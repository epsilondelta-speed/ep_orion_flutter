import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';
import 'orion_frame_metrics.dart';
import 'orion_rage_click_tracker.dart';

/// RouteObserver with comprehensive frame tracking and interaction-aware TTFD
///
/// Features:
/// - Accurate TTID/TTFD with frame stability
/// - Interaction-aware TTFD: captures on first interaction if no stable frames yet
/// - Real janky/frozen frame detection
/// - Top 10 jank clusters with ultra-compact beacon
/// - Frozen frames tracked separately
/// - Waterfall UI ready (timestamps included)
/// - Battery lifecycle integration for accurate battery metrics
/// - Background tracking per screen (wentBg, bgCount)
/// - ✅ NEW: Rage click tracking per screen
///
/// TTFD Logic:
/// 1. If 3 stable frames (≤16ms) before user interaction → TTFD = stable frame time
/// 2. If user interacts before 3 stable frames → TTFD = interaction time
/// 3. Timeout at 10s as fallback
///
/// Usage:
/// ```dart
/// MaterialApp(
///   navigatorObservers: [OrionScreenTracker()],
///   builder: (context, child) {
///     return OrionRageClickDetector(  // ✅ Wrap with rage click detector
///       child: OrionInteractionDetector(child: child!),
///     );
///   },
/// )
/// ```
class OrionScreenTracker extends RouteObserver<PageRoute<dynamic>> {
  final Map<String, _ScreenMetrics> _screenMetrics = {};

  // Manual TTFD support
  static final Map<String, bool> _manualTTFDFlags = {};

  // Singleton instance for interaction detection
  static OrionScreenTracker? _instance;

  OrionScreenTracker() {
    _instance = this;
  }

  /// Get current instance (for interaction detection)
  static OrionScreenTracker? get instance => _instance;

  /// Current screen being tracked
  String? _currentScreenName;

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (!OrionFlutter.isSupported) return;

    _finalizeTracking(previousRoute);
    _updateCurrentScreen(route);
    _startTracking(route);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (!OrionFlutter.isSupported) return;

    _finalizeTracking(oldRoute);
    _updateCurrentScreen(newRoute);
    _startTracking(newRoute);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    if (!OrionFlutter.isSupported) return;

    _finalizeTracking(route);
    _updateCurrentScreen(previousRoute);
  }

  void _updateCurrentScreen(Route? route) {
    if (!OrionFlutter.isSupported) return;

    if (route is PageRoute) {
      final screenName = route.settings.name ?? route.runtimeType.toString();
      _currentScreenName = screenName;
      OrionNetworkTracker.setCurrentScreen(screenName);

      // ✅ NEW: Set current screen for rage click tracker
      OrionRageClickTracker.setCurrentScreen(screenName);

      orionPrint("📍 OrionScreenTracker: currentScreenName set to $screenName");
    }
  }

  void _startTracking(Route? route) {
    if (!OrionFlutter.isSupported) return;

    if (route is PageRoute) {
      final screenName = route.settings.name ?? route.runtimeType.toString();
      final metrics = _ScreenMetrics(screenName);
      _screenMetrics[screenName] = metrics;
      metrics.begin();

      // Notify native side for battery tracking
      OrionFlutter.onFlutterScreenStart(screenName);
    }
  }

  void _finalizeTracking(Route? route) {
    if (!OrionFlutter.isSupported) return;

    if (route is PageRoute) {
      final screenName = route.settings.name ?? route.runtimeType.toString();
      final metrics = _screenMetrics.remove(screenName);

      // Notify native side for battery tracking BEFORE sending beacon
      OrionFlutter.onFlutterScreenStop(screenName);

      metrics?.send();

      _manualTTFDFlags.remove(screenName);
    }
  }

  /// Mark screen as fully drawn (for async content)
  static void markFullyDrawn(String screenName) {
    if (!OrionFlutter.isSupported) return;

    _manualTTFDFlags[screenName] = true;
    orionPrint("🎯 [$screenName] Manual TTFD triggered");
  }

  static bool _hasManualTTFD(String screenName) {
    return _manualTTFDFlags[screenName] == true;
  }

  /// Notify interaction on current screen
  void notifyInteraction() {
    if (_currentScreenName != null && _screenMetrics.containsKey(_currentScreenName)) {
      _screenMetrics[_currentScreenName]?.onUserInteraction();
    }
  }

  /// Static method for interaction detection widget
  static void onInteraction() {
    _instance?.notifyInteraction();
  }

  /// Notify current screen that app went to background
  static void onAppWentToBackground() {
    if (_instance?._currentScreenName != null) {
      _instance?._screenMetrics[_instance!._currentScreenName]?.onAppBackground();
    }
  }

  /// Notify current screen that app came to foreground
  static void onAppCameToForeground() {
    if (_instance?._currentScreenName != null) {
      _instance?._screenMetrics[_instance!._currentScreenName]?.onAppForeground();
    }
  }
}

/// Interaction detector widget - wrap your app with this
///
/// Usage Option 1 (with MaterialApp builder):
/// ```dart
/// MaterialApp(
///   navigatorObservers: [OrionScreenTracker()],
///   builder: (context, child) {
///     return OrionInteractionDetector(child: child!);
///   },
/// )
/// ```
///
/// Usage Option 2 (wrap entire app):
/// ```dart
/// OrionInteractionDetector(
///   child: MaterialApp(
///     navigatorObservers: [OrionScreenTracker()],
///     ...
///   ),
/// )
/// ```
class OrionInteractionDetector extends StatelessWidget {
  final Widget child;

  const OrionInteractionDetector({Key? key, required this.child}) : super(key: key);

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

/// App Lifecycle Observer for accurate battery tracking
///
/// Add this to your main.dart to track app foreground/background for battery:
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   OrionAppLifecycleObserver.initialize();
///   runApp(MyApp());
/// }
/// ```
class OrionAppLifecycleObserver with WidgetsBindingObserver {
  static OrionAppLifecycleObserver? _instance;
  static bool _isInForeground = true;

  OrionAppLifecycleObserver._();

  /// Initialize the app lifecycle observer
  static void initialize() {
    if (_instance == null) {
      _instance = OrionAppLifecycleObserver._();
      WidgetsBinding.instance.addObserver(_instance!);
      orionPrint("🔋 OrionAppLifecycleObserver initialized");

      // Notify foreground on startup (non-blocking)
      _notifyForegroundAsync();
    }
  }

  /// Non-blocking foreground notification
  static void _notifyForegroundAsync() {
    Future.microtask(() {
      OrionFlutter.onAppForeground();
      OrionScreenTracker.onAppCameToForeground();
    });
  }

  /// Non-blocking background notification
  static void _notifyBackgroundAsync() {
    Future.microtask(() {
      OrionFlutter.onAppBackground();
      OrionScreenTracker.onAppWentToBackground();
    });
  }

  /// Dispose the observer (call when app is terminating)
  static void dispose() {
    if (_instance != null) {
      WidgetsBinding.instance.removeObserver(_instance!);
      _instance = null;
    }
  }

  /// Check if app is currently in foreground
  static bool get isInForeground => _isInForeground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isInForeground) {
          _isInForeground = true;
          orionPrint("🔋 App resumed (foreground)");
          _notifyForegroundAsync();
        }
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        if (_isInForeground) {
          _isInForeground = false;
          orionPrint("🔋 App paused (background)");
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
  }
}

class _ScreenMetrics {
  final String screenName;
  final Stopwatch _stopwatch = Stopwatch();

  // TTID/TTFD
  int _ttid = -1;
  int _ttfd = -1;
  bool _ttidCaptured = false;
  bool _ttfdCaptured = false;
  bool _ttfdManual = false;

  // Interaction tracking
  bool _userInteracted = false;
  int _interactionTime = -1;
  String _ttfdSource = 'unknown';

  // Background tracking for this screen
  bool _wentToBackground = false;
  int _backgroundCount = 0;

  // Frame stability tracking
  int _stableFrameCount = 0;
  static const int _requiredStableFrames = 3;
  static const int _maxFrameDuration = 16;
  int? _lastFrameTime;

  // Timeout
  static const int _ttfdTimeoutMs = 5000;

  bool _disposed = false;

  _ScreenMetrics(this.screenName);

  void begin() {
    if (!OrionFlutter.isSupported) return;

    _stopwatch.start();

    // Reset background tracking for this screen
    _wentToBackground = false;
    _backgroundCount = 0;

    // Start TTID tracking
    _captureTTID();

    // Start TTFD tracking
    _startTTFDTracking();

    // Start frame metrics tracking
    OrionFrameMetrics.startTracking(screenName);
  }

  /// Called when app goes to background during this screen
  void onAppBackground() {
    if (_disposed) return;

    _wentToBackground = true;
    _backgroundCount++;

    orionPrint("📱 [$screenName] App went to background (count: $_backgroundCount)");
  }

  /// Called when app comes to foreground during this screen
  void onAppForeground() {
    if (_disposed) return;

    orionPrint("📱 [$screenName] App came to foreground");
  }

  /// Called when user interacts with the screen
  void onUserInteraction() {
    if (_userInteracted || _ttfdCaptured || _disposed) return;

    _userInteracted = true;
    _interactionTime = _stopwatch.elapsedMilliseconds;

    orionPrint("👆 [$screenName] User interaction detected at $_interactionTime ms");

    // If TTFD not captured yet, capture it now
    if (!_ttfdCaptured) {
      _ttfd = _interactionTime;
      _ttfdCaptured = true;
      _ttfdSource = 'interaction';

      orionPrint("✅ [$screenName] TTFD (interaction): $_ttfd ms");
    }
  }

  void _captureTTID() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _ttidCaptured) return;

      _ttid = _stopwatch.elapsedMilliseconds;
      _ttidCaptured = true;

      orionPrint("🎨 [$screenName] TTID: $_ttid ms");
    });
  }

  void _startTTFDTracking() {
    if (OrionScreenTracker._hasManualTTFD(screenName)) {
      _startManualTTFDTracking();
    } else {
      _startAutomaticTTFDTracking();
    }
  }

  void _startAutomaticTTFDTracking() {
    SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _startManualTTFDTracking() {
    orionPrint("⏳ [$screenName] Waiting for manual TTFD trigger...");
    _pollForManualTTFD();
  }

  void _pollForManualTTFD() {
    if (_disposed || _ttfdCaptured) return;

    if (OrionScreenTracker._hasManualTTFD(screenName)) {
      _ttfd = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdManual = true;
      _ttfdSource = 'manual';

      orionPrint("✅ [$screenName] Manual TTFD captured: $_ttfd ms");
      return;
    }

    if (_stopwatch.elapsedMilliseconds > _ttfdTimeoutMs) {
      _ttfd = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource = 'timeout';
      orionPrint("⚠️ [$screenName] Manual TTFD timeout: $_ttfd ms");
      return;
    }

    Future.delayed(const Duration(milliseconds: 50), _pollForManualTTFD);
  }

  void _onFrame(Duration timestamp) {
    if (_disposed || _ttfdCaptured) return;

    final currentTime = timestamp.inMilliseconds;

    // Check timeout
    if (_stopwatch.elapsedMilliseconds > _ttfdTimeoutMs) {
      _ttfd = _stopwatch.elapsedMilliseconds;
      _ttfdCaptured = true;
      _ttfdSource = 'timeout';
      orionPrint("⚠️ [$screenName] TTFD timeout: $_ttfd ms");
      return;
    }

    if (_lastFrameTime != null) {
      final frameDuration = currentTime - _lastFrameTime!;

      if (frameDuration <= _maxFrameDuration) {
        _stableFrameCount++;

        if (_stableFrameCount >= _requiredStableFrames) {
          _ttfd = _stopwatch.elapsedMilliseconds;
          _ttfdCaptured = true;
          _ttfdSource = 'stable_frames';

          orionPrint("✅ [$screenName] TTFD (stable): $_ttfd ms");
          return;
        }
      } else {
        if (frameDuration > 32) {
          _stableFrameCount = 0;
        }
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

    // Wait to ensure TTFD and frame metrics are captured
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!OrionFlutter.isSupported) return;

      if (!_ttfdCaptured) {
        _ttfd = _stopwatch.elapsedMilliseconds;
        _ttfdCaptured = true;
        _ttfdSource = 'finalize';
      }

      // Stop frame metrics tracking and get results
      final frameMetrics = OrionFrameMetrics.stopTracking(screenName);

      final networkData = OrionNetworkTracker.consumeRequestsForScreen(screenName);

      // ✅ NEW: Get rage clicks for this screen
      final rageClicks = OrionRageClickTracker.getRageClicksJson(screenName);
      final rageClickCount = OrionRageClickTracker.getRageClickCount(screenName);

      // Clear rage clicks after getting data
      OrionRageClickTracker.clearScreen(screenName);

      final bgInfo = _wentToBackground ? ' (went bg: $_backgroundCount times)' : '';
      final rageInfo = rageClickCount > 0 ? ' 🔴 Rage clicks: $rageClickCount' : '';

      orionPrint(
          "📤 [$screenName] Sending beacon:\n"
              "   TTID: $_ttid ms\n"
              "   TTFD: $_ttfd ms (source: $_ttfdSource)\n"
              "   User interacted: $_userInteracted${_userInteracted ? ' at ${_interactionTime}ms' : ''}\n"
              "   Went to background: $_wentToBackground (count: $_backgroundCount)$bgInfo\n"
              "   Janky: ${frameMetrics.jankyFrames}/${frameMetrics.totalFrames} frames\n"
              "   Frozen: ${frameMetrics.frozenFrames} frames\n"
              "   Clusters: ${frameMetrics.top10Clusters.length}\n"
              "   Avg frame: ${frameMetrics.avgFrameDuration.toStringAsFixed(2)}ms\n"
              "   Worst frame: ${frameMetrics.worstFrameDuration.toStringAsFixed(2)}ms\n"
              "   Network: ${networkData.length} requests$rageInfo"
      );

      // Get ultra-compact beacon with shorthand names
      final frameBeacon = frameMetrics.toBeacon();

      // Add TTFD source and interaction info to frame beacon
      frameBeacon['ttfdSrc'] = _ttfdSource;
      if (_userInteracted) {
        frameBeacon['intTime'] = _interactionTime;
      }

      // Add ttfdManual flag
      final bool ttfdManualFlag = _ttfdSource == 'manual';

      // Pass frame metrics as separate parameter
      OrionFlutter.trackFlutterScreen(
        screen: screenName,
        ttid: _ttid,
        ttfd: _ttfd,
        ttfdManual: ttfdManualFlag,
        jankyFrames: frameMetrics.jankyFrames,
        frozenFrames: frameMetrics.frozenFrames,
        network: networkData,
        frameMetrics: frameBeacon,
        wentBg: _wentToBackground,
        bgCount: _backgroundCount,
        rageClicks: rageClicks,           // ✅ NEW
        rageClickCount: rageClickCount,   // ✅ NEW
      );
    });
  }
}