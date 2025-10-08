import 'package:flutter/widgets.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';

class OrionManualTracker {
  static final Map<String, _ManualScreenMetrics> _screenMetrics = {};
  static final List<String> _screenHistoryStack = [];

  /// 🔄 Start tracking a screen manually
  static void startTracking(String screenName) {
    if (!OrionFlutter.isAndroid) return;

    orionPrint("🚀 [Orion] startTracking() called for: $screenName");

    if (_screenMetrics.containsKey(screenName)) {
      orionPrint("⚠️ [Orion] Already tracking screen: $screenName. Skipping.");
      return;
    }

    if (_screenHistoryStack.isEmpty || _screenHistoryStack.last != screenName) {
      _screenHistoryStack.add(screenName);
      orionPrint("📚 [Orion] Pushed $screenName to screen history");
    }

    OrionNetworkTracker.setCurrentScreen(screenName);
    orionPrint("📍 OrionManualTracker: currentScreenName set to $screenName");

    final metrics = _ManualScreenMetrics(screenName);
    _screenMetrics[screenName] = metrics;
    metrics.begin();

    orionPrint("✅ [Orion] Started tracking screen: $screenName");
  }

  /// ✅ Finalize tracking and send beacon
  static void finalizeScreen(String screenName) {
    if (!OrionFlutter.isAndroid) return;

    orionPrint("📥 [Orion] finalizeScreen() called for: $screenName");

    final metrics = _screenMetrics.remove(screenName);

    if (_screenHistoryStack.isNotEmpty && _screenHistoryStack.last == screenName) {
      _screenHistoryStack.removeLast();
      orionPrint("📚 [Orion] Popped $screenName from screen history");
    }

    if (metrics == null) {
      orionPrint("⚠️ [Orion] No tracking data found for: $screenName. Skipping send.");
      return;
    }

    metrics.send();
    orionPrint("📤 [Orion] Sent metrics for screen: $screenName");
  }

  /// 🧠 Resume previous screen from stack (for back navigation)
  static void resumePreviousScreen() {
    if (!OrionFlutter.isAndroid) return;

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
    if (!OrionFlutter.isAndroid) return null;

    if (_screenHistoryStack.length >= 2) {
      return _screenHistoryStack[_screenHistoryStack.length - 2];
    } else {
      orionPrint("⚠️ [Orion] No previous screen in history stack");
      return null;
    }
  }

  static bool hasTracked(String screenName) {
    if (!OrionFlutter.isAndroid) return false;

    final exists = _screenMetrics.containsKey(screenName);
    orionPrint("🔍 [Orion] hasTracked($screenName): $exists");
    return exists;
  }
}

class _ManualScreenMetrics {
  final String screenName;
  final Stopwatch _stopwatch = Stopwatch();
  int _ttid = -1;
  bool _ttfdCaptured = false;

  _ManualScreenMetrics(this.screenName);

  void begin() {
    _stopwatch.start();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ttid = _stopwatch.elapsedMilliseconds;
    });

    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      if (_ttfdCaptured) return;
      _ttfdCaptured = true;

      Future.delayed(const Duration(milliseconds: 500), () {
        final ttfd = _stopwatch.elapsedMilliseconds;
        final janky = _mockJankyFrames();
        final frozen = _mockFrozenFrames();

        _ttfdFinal = ttfd;
        _jankyFinal = janky;
        _frozenFinal = frozen;
      });
    });
  }

  int _ttfdFinal = -1;
  int _jankyFinal = 0;
  int _frozenFinal = 0;

  void send() {
    if (!OrionFlutter.isAndroid) return;

    final networkData = OrionNetworkTracker.consumeRequestsForScreen(screenName);

    OrionFlutter.trackFlutterScreen(
      screen: screenName,
      ttid: _ttid,
      ttfd: _ttfdFinal,
      jankyFrames: _jankyFinal,
      frozenFrames: _frozenFinal,
      network: networkData,
    );
  }

  int _mockJankyFrames() => 0;
  int _mockFrozenFrames() => 0;
}