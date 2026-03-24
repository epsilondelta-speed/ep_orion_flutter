import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';
import 'orion_frame_metrics.dart';
import 'orion_rage_click_tracker.dart';  // ✅ NEW: Import rage click tracker

/// Manual screen tracker for non-MaterialApp navigation
///
/// Features:
/// - Accurate TTID/TTFD with frame stability detection
/// - Interaction-aware TTFD: captures on first interaction if no stable frames yet
/// - Real janky/frozen frame detection
/// - Top 10 jank clusters with ultra-compact beacon
/// - Frozen frames tracked separately
/// - Screen history stack management
/// - Manual TTFD support for async content
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
/// // When navigating to a screen
/// OrionManualTracker.startTracking('HomeScreen');
///
/// // When leaving a screen
/// OrionManualTracker.finalizeScreen('HomeScreen');
///
/// // For async content (optional)
/// OrionManualTracker.markFullyDrawn('HomeScreen');
/// ```
class OrionManualTracker {
  static final Map<String, _ManualScreenMetrics> _screenMetrics = {};
  static final List<String> _screenHistoryStack = [];

  // Manual TTFD support
  static final Map<String, bool> _manualTTFDFlags = {};

  /// 🔄 Start tracking a screen manually
  static void startTracking(String screenName) {
    if (!OrionFlutter.isSupported) return;

    orionPrint("🚀 [Orion] startTracking() called for: $screenName");

    // If already tracking, finalize previous tracking first
    if (_screenMetrics.containsKey(screenName)) {
      orionPrint("⚠️ [Orion] Already tracking screen: $screenName. Finalizing previous...");
      finalizeScreen(screenName);
    }

    // Update screen history stack
    if (_screenHistoryStack.isEmpty || _screenHistoryStack.last != screenName) {
      _screenHistoryStack.add(screenName);
      orionPrint("📚 [Orion] Pushed $screenName to screen history");
    }

    // Set current screen for network tracking
    OrionNetworkTracker.setCurrentScreen(screenName);
    orionPrint("📍 OrionManualTracker: currentScreenName set to $screenName");

    // ✅ NEW: Set current screen for rage click tracker
    OrionRageClickTracker.setCurrentScreen(screenName);

    // Notify native side for battery tracking
    OrionFlutter.onFlutterScreenStart(screenName);

    // Start tracking metrics
    final metrics = _ManualScreenMetrics(screenName);
    _screenMetrics[screenName] = metrics;
    metrics.begin();

    orionPrint("✅ [Orion] Started tracking screen: $screenName");
  }

  /// ✅ Finalize tracking and send beacon
  static void finalizeScreen(String screenName) {
    if (!OrionFlutter.isSupported) return;

    orionPrint("🔥 [Orion] finalizeScreen() called for: $screenName");

    final metrics = _screenMetrics.remove(screenName);

    // Update screen history stack
    if (_screenHistoryStack.isNotEmpty && _screenHistoryStack.last == screenName) {
      _screenHistoryStack.removeLast();
      orionPrint("📚 [Orion] Popped $screenName from screen history");
    }

    // Clean up manual TTFD flag
    _manualTTFDFlags.remove(screenName);

    // Notify native side for battery tracking BEFORE sending beacon
    OrionFlutter.onFlutterScreenStop(screenName);

    if (metrics == null) {
      orionPrint("⚠️ [Orion] No tracking data found for: $screenName. Skipping send.");
      return;
    }

    metrics.send();
    orionPrint("📤 [Orion] Sent metrics for screen: $screenName");
  }

  /// 🧠 Resume previous screen from stack (for back navigation)
  static void resumePreviousScreen() {
    if (!OrionFlutter.isSupported) return;

    if (_screenHistoryStack.length >= 1) {
      final previous = _screenHistoryStack.last;
      orionPrint("🔁 [Orion] Resumed tracking for previous screen: $previous");
      startTracking(previous);
    } else {
      orionPrint("⚠️ [Orion] No previous screen to resume in stack");
    }
  }

  /// 🔍 Peek the second-last screen name (without modifying stack)
  static String? getLastTrackedScreen() {
    if (!OrionFlutter.isSupported) return null;

    if (_screenHistoryStack.length >= 2) {
      return _screenHistoryStack[_screenHistoryStack.length - 2];
    } else {
      orionPrint("⚠️ [Orion] No previous screen in history stack");
      return null;
    }
  }

  /// Check if screen is currently being tracked
  static bool hasTracked(String screenName) {
    if (!OrionFlutter.isSupported) return false;

    final exists = _screenMetrics.containsKey(screenName);
    orionPrint("🔍 [Orion] hasTracked($screenName): $exists");
    return exists;
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

  /// Get current screen being tracked (for interaction detection)
  static String? get currentScreen {
    return _screenHistoryStack.isNotEmpty ? _screenHistoryStack.last : null;
  }

  /// Notify interaction on current screen
  static void notifyInteraction() {
    final screen = currentScreen;
    if (screen != null && _screenMetrics.containsKey(screen)) {
      _screenMetrics[screen]?.onUserInteraction();
    }
  }

  /// Notify current screen that app went to background
  static void onAppWentToBackground() {
    final screen = currentScreen;
    if (screen != null && _screenMetrics.containsKey(screen)) {
      _screenMetrics[screen]?.onAppBackground();
    }
  }

  /// Notify current screen that app came to foreground
  static void onAppCameToForeground() {
    final screen = currentScreen;
    if (screen != null && _screenMetrics.containsKey(screen)) {
      _screenMetrics[screen]?.onAppForeground();
    }
  }
}

/// Interaction detector widget - wrap your app with this
///
/// Usage:
/// ```dart
/// OrionInteractionDetector(
///   child: MaterialApp(...),
/// )
/// ```
class OrionManualInteractionDetector extends StatelessWidget {
  final Widget child;

  const OrionManualInteractionDetector({Key? key, required this.child}) : super(key: key);

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

/// App Lifecycle Observer for accurate battery tracking (Manual Tracker version)
///
/// Add this to your main.dart to track app foreground/background for battery:
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   OrionManualAppLifecycleObserver.initialize();
///   runApp(MyApp());
/// }
/// ```
class OrionManualAppLifecycleObserver with WidgetsBindingObserver {
  static OrionManualAppLifecycleObserver? _instance;
  static bool _isInForeground = true;

  OrionManualAppLifecycleObserver._();

  /// Initialize the app lifecycle observer
  static void initialize() {
    if (_instance == null) {
      _instance = OrionManualAppLifecycleObserver._();
      WidgetsBinding.instance.addObserver(_instance!);
      orionPrint("🔋 OrionManualAppLifecycleObserver initialized");

      // Notify foreground on startup (non-blocking)
      _notifyForegroundAsync();
    }
  }

  /// Non-blocking foreground notification
  static void _notifyForegroundAsync() {
    Future.microtask(() {
      OrionFlutter.onAppForeground();
      OrionManualTracker.onAppCameToForeground();
    });
  }

  /// Non-blocking background notification
  static void _notifyBackgroundAsync() {
    Future.microtask(() {
      OrionFlutter.onAppBackground();
      OrionManualTracker.onAppWentToBackground();
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

class _ManualScreenMetrics {
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

  _ManualScreenMetrics(this.screenName);

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
    if (OrionManualTracker._hasManualTTFD(screenName)) {
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

    if (OrionManualTracker._hasManualTTFD(screenName)) {
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