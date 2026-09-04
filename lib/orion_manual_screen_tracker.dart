import 'package:flutter/widgets.dart';
import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'orion_flutter.dart';
import 'orion_network_tracker.dart';
import 'orion_logger.dart';
import 'orion_frame_metrics.dart';
import 'orion_rage_click_tracker.dart';
import 'orion_beacon_guard.dart';
import 'orion_lifecycle.dart';

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

/// Retained for source compatibility. All behaviour now lives in
/// [OrionLifecycle], which is the SDK's single observer — see that class for
/// why there is only one.
///
/// As of 1.2.36 calling this is OPTIONAL: `initializeEdOrion` registers the
/// observer itself. Both entry points share one instance, so a host that calls
/// this as well gets a no-op rather than a second registration.
class OrionManualAppLifecycleObserver {
  OrionManualAppLifecycleObserver._();

  static void initialize() {
    try {
      OrionLifecycle.ensureRegistered();
    } catch (e) {
      orionPrint('⚠️ OrionManualAppLifecycleObserver: initialize error: $e');
    }
  }

  static void dispose() => OrionLifecycle.dispose();

  static bool get isInForeground => OrionLifecycle.isInForeground;
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

  // ── TTFD detection state (1.2.36) ────────────────────────────────────
  // _settleTimer detects "no frames for a while"; _ttfdTimeoutTimer is the
  // hard cap. Both are cancelled on capture and on send(), so a screen that is
  // finalized mid-detection leaves nothing running.
  Timer? _settleTimer;
  Timer? _ttfdTimeoutTimer;
  int _lastFrameElapsed = -1;
  static const int _settleWindowMs = 200;
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

  /// Passive TTFD detection (1.2.36).
  ///
  /// scheduleFrameCallback's `scheduleNewFrame` defaults to true and its
  /// first statement is scheduleFrame(), so the previous self-rescheduling
  /// loop REQUESTED a vsync on every frame and held the engine at full
  /// refresh rate until TTFD was captured or the 5 s cap hit. That is the
  /// same forced-render-loop the frame tracker was moved off in 1.2.32; the
  /// TTFD path was missed at the time. It violates the invariant that frame
  /// metrics observe and never drive.
  void _startTTFDTracking() {
    if (OrionManualTracker._hasManualTTFD(screenName)) {
      _pollForManualTTFD();
      return;
    }
    _armTTFDTimeout();
    SchedulerBinding.instance
        .scheduleFrameCallback(_onFrame, scheduleNewFrame: false);
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
    _lastFrameElapsed = _stopwatch.elapsedMilliseconds;

    if (_lastFrameTime != null) {
      final frameDuration = currentTime - _lastFrameTime!;
      if (frameDuration <= _maxFrameDuration) {
        _stableFrameCount++;
        if (_stableFrameCount >= _requiredStableFrames) {
          _captureTTFD(_stopwatch.elapsedMilliseconds, 'stable_frames');
          return;
        }
      } else {
        if (frameDuration > 32) _stableFrameCount = 0;
      }
    }

    _lastFrameTime = currentTime;

    // Settle detection. If no further frame arrives within _settleWindowMs the
    // screen has stopped changing, which is what TTFD is actually asking. We
    // report the LAST OBSERVED frame's elapsed time rather than the moment the
    // timer fired, so TTFD does not carry the window length as a constant
    // offset. The timer is restarted on every frame, so a screen that is still
    // painting keeps pushing it out.
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: _settleWindowMs), () {
      // A screen cannot be "fully drawn" before it has been drawn at all.
      // _onFrame is a TRANSIENT callback — it runs at the START of a frame —
      // while TTID is captured in that same frame's post-frame callback. On a
      // slow device a single heavy frame can outlast the settle window, so
      // firing here would report the frame's start as TTFD and produce a TTFD
      // that precedes TTID. Measured on a low-end device before this guard: 51
      // of 61 beacons inverted. Wait for the frame to finish; the 5 s cap
      // bounds this, so it cannot spin forever.
      if (!_ttidCaptured) {
        _settleTimer = Timer(const Duration(milliseconds: _settleWindowMs), () {
          _captureTTFD(_lastFrameElapsed, 'settled');
        });
        return;
      }
      _captureTTFD(_lastFrameElapsed, 'settled');
    });

    // scheduleNewFrame: false — observe, never drive. See _startTTFDTracking.
    SchedulerBinding.instance
        .scheduleFrameCallback(_onFrame, scheduleNewFrame: false);
  }

  /// Records TTFD exactly once and shuts down both TTFD timers.
  void _captureTTFD(int elapsedMs, String source) {
    if (_disposed || _ttfdCaptured) return;
    // Belt and braces for the ordering described on the settle timer: TTFD is
    // never allowed to precede TTID. Downstream treats ttid > ttfd as a bogus
    // TTFD and substitutes ttid + 50, so an inverted value is not merely odd —
    // it silently discards the measurement.
    _ttfd         = (_ttidCaptured && elapsedMs < _ttid) ? _ttid : elapsedMs;
    _ttfdCaptured = true;
    _ttfdSource   = source;
    _cancelTTFDTimers();
    orionPrint('✅ [$screenName] TTFD ($source): $_ttfd ms');
  }

  void _cancelTTFDTimers() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _ttfdTimeoutTimer?.cancel();
    _ttfdTimeoutTimer = null;
  }

  /// Hard cap on TTFD, driven by a Timer rather than from inside _onFrame.
  ///
  /// The old implementation checked the 5 s cap at the top of the frame
  /// callback, which only worked because that callback FORCED a vsync every
  /// frame. With passive observation an idle screen delivers no callbacks at
  /// all, so a cap living in the frame path could never fire.
  void _armTTFDTimeout() {
    _ttfdTimeoutTimer?.cancel();
    _ttfdTimeoutTimer = Timer(const Duration(milliseconds: _ttfdTimeoutMs), () {
      _captureTTFD(_stopwatch.elapsedMilliseconds, 'timeout');
    });
  }

  void send() {
    if (!OrionFlutter.isSupported || _disposed) return;
    _disposed = true;
    _cancelTTFDTimers();

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

        // 1.2.36 — suppress beacons that carry no measurement at all.
        //
        // A host can finalize a screen microseconds after starting it. The
        // customer pattern that surfaced this finalizes the GLOBAL
        // OrionNetworkTracker.currentScreenName from a page's dispose(), which by
        // then points at the screen just pushed rather than the one being
        // destroyed. The tracker exists but has captured nothing, so we emitted a
        // row of ttid: -1, totFrm: 0, empty network — data-shaped noise that
        // pollutes per-screen averages downstream.
        //
        // This is not a guess about the caller's intent. The four clauses together
        // state a fact: no TTID, no rendered frames, no requests, no rage clicks,
        // therefore nothing to report. Each clause is load-bearing — a screen that
        // never rendered but did fire requests is still worth sending.
        //
        // This suppresses the noise; it does not recover the measurement. The real
        // TTID/TTFD is already lost by the time we reach here. A host seeing screens
        // go missing should fix the finalize call, not rely on this.
        if (shouldSuppressEmptyBeacon(
          ttid:           _ttid,
          totalFrames:    frameMetrics.totalFrames,
          networkCount:   networkData.length,
          rageClickCount: rageClickCount,
        )) {
          orionPrint('⏭️ [$screenName] No data collected — suppressing empty beacon');
          return;
        }

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
