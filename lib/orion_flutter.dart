import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'orion_flutter_platform_interface.dart';
import 'orion_sampling_manager.dart';
import 'orion_http_overrides.dart';
import 'orion_cold_start.dart';
import 'orion_logger.dart';

export 'orion_wake_lock.dart';
export 'orion_rage_click_tracker.dart';
export 'orion_rage_click_detector.dart';
export 'orion_http_overrides.dart';

class OrionFlutter {
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  static bool _isReportingError = false;

  // ✅ Fix #14: dedupe by (exception + first stack frame) so two distinct
  //    exceptions with the same message string aren't merged, and the same
  //    exception rethrown from different sites isn't merged either.
  static String? _lastErrorKey;
  static DateTime? _lastErrorTime;
  static const Duration _errorDedupeWindow = Duration(seconds: 10);

  static bool get isAndroid   => Platform.isAndroid;
  static bool get isIOS       => Platform.isIOS;
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Initializes Orion SDK on both Android and iOS.
  static Future<String?> initializeEdOrion({
    required String cid,
    required String pid,
    double sampleRate = 1.0,
    bool trackAllHttp = false,
  }) async {
    if (!isSupported) return 'Skipped: unsupported platform';

    try {
      if (trackAllHttp) {
        OrionHttpOverrides.install(); // already wrapped in try-catch internally
      }

      SamplingManager.instance.initialize(cid, pid, sampleRate: sampleRate);

      // Cold-start (1.2.26): arm the one-shot first-frame mark. Android-only
      // internally; a no-op on iOS and safe if the binding isn't ready.
      OrionColdStart.armFirstFrameMark();

      return await _channel.invokeMethod<String>('initializeEdOrion', {
        'cid': cid,
        'pid': pid,
        // Lets the native layer turn its own logging on in a debug host build.
        // It cannot determine this itself — the only BuildConfig it can see is
        // the SDK's own, and the published Android AAR is a release variant, so
        // its DEBUG constant is false in every customer build. kDebugMode is
        // compile-time constant, so this is `false` in release and the native
        // logger stays off, exactly as before.
        'debug': kDebugMode,
      });
    } catch (e) {
      orionPrint('initializeEdOrion error — $e');
      return null;
    }
  }

  static Future<String?> getPlatformVersion() {
    return OrionFlutterPlatform.instance.getPlatformVersion();
  }

  static Future<String?> getRuntimeMetrics() {
    if (!isSupported) return Future.value(null);
    return OrionFlutterPlatform.instance.getRuntimeMetrics();
  }

  // ── Error Tracking ────────────────────────────────────────────────────────

  // Error beacons are NEVER gated by sampling — they always send.

  /// Build a dedupe key from (exception text + first stack frame).
  ///
  /// Using just the exception string was too aggressive: two genuinely different
  /// errors with identical messages got coalesced. Using exception + a single
  /// site-identifying frame is much closer to "is this the same bug?" without
  /// being so specific that a recurring bug avoids dedupe.
  static String _buildDedupeKey(String exception, String stack) {
    try {
      // First non-empty line of the stack — typically the throw site or the
      // top frame of the framework that raised the error.
      final firstFrame = stack
          .split('\n')
          .map((s) => s.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      return '$exception::$firstFrame';
    } catch (_) {
      return exception;
    }
  }

  static bool _shouldDedupe(String exception, String stack) {
    final key = _buildDedupeKey(exception, stack);
    final now = DateTime.now();
    if (_lastErrorKey == key &&
        _lastErrorTime != null &&
        now.difference(_lastErrorTime!) < _errorDedupeWindow) {
      return true;
    }
    _lastErrorKey  = key;
    _lastErrorTime = now;
    return false;
  }

  static Future<void> trackFlutterErrorRaw({
    required String exception,
    required String stack,
    String? library,
    String? context,
    String? screen,
    List<Map<String, dynamic>>? network,
  }) async {
    if (!isSupported || _isReportingError) return;

    // ✅ Fix #14: dedupe key now combines exception + first stack frame so
    //    two distinct errors with the same message aren't merged, and the
    //    same exception rethrown from different sites isn't merged either.
    if (_shouldDedupe(exception, stack)) return;

    _isReportingError = true;

    try {
      await _channel.invokeMethod('trackFlutterError', {
        'exception': exception,
        'stack':     stack,
        'library':   library ?? '',
        'context':   context ?? '',
        'screen':    screen  ?? 'UnknownScreen',
        'network':   network ?? [],
      });
    } catch (_) {
    } finally {
      _isReportingError = false;
    }
  }

  static void trackUnhandledError(Object error, StackTrace stack,
      {String? screen, List<Map<String, dynamic>>? network}) {
    if (!isSupported || _isReportingError) return;
    _isReportingError = true;
    try {
      _channel.invokeMethod('trackFlutterError', {
        'exception': error.toString(),
        'stack':     stack.toString(),
        'library':   '',
        'context':   '',
        'screen':    screen ?? 'UnknownScreen',
        'network':   network ?? [],
      });
    } catch (_) {
    } finally {
      _isReportingError = false;
    }
  }

  // ── Screen Beacon ─────────────────────────────────────────────────────────

  static Future<void> trackFlutterScreen({
    required String screen,
    int ttid                              = -1,
    int ttfd                              = -1,
    bool ttfdManual                       = false,
    int jankyFrames                       = 0,
    int frozenFrames                      = 0,
    List<Map<String, dynamic>> network    = const [],
    Map<String, dynamic>? frameMetrics,
    bool wentBg                           = false,
    int bgCount                           = 0,
    List<Map<String, dynamic>> rageClicks = const [],
    int rageClickCount                    = 0,
  }) async {
    if (!isSupported) return;

    try {
      if (!SamplingManager.instance.shouldSend()) {
        orionPrint('Beacon dropped by sampling '
            '(effective: ${SamplingManager.instance.getEffectivePercent()}%)');
        return;
      }

      // ✅ Verbose beacon preview is guarded by kDebugMode so it never runs
      //    in production, avoiding the cost of JsonEncoder.withIndent on every
      //    screen transition.
      if (kDebugMode) {
        orionPrint(
          '\n========== ORION BEACON (Dart) ==========\n'
              'screen=$screen ttid=$ttid ttfd=$ttfd '
              'janky=$jankyFrames frozen=$frozenFrames '
              'network=${network.length} rageClicks=$rageClickCount'
              '\n=========================================',
        );
      }

      await _channel.invokeMethod('trackFlutterScreen', {
        'screen':         screen,
        'ttid':           ttid,
        'ttfd':           ttfd,
        'ttfdManual':     ttfdManual,
        'jankyFrames':    jankyFrames,
        'frozenFrames':   frozenFrames,
        'network':        network,
        'frameMetrics':   frameMetrics,
        'wentBg':         wentBg,
        'bgCount':        bgCount,
        'rageClicks':     rageClicks,
        'rageClickCount': rageClickCount,

        // The config that actually produced this beacon's send/drop decision.
        //
        // `cf` exists to record which config a decision was made under, but the
        // decision is made HERE (shouldSend() above) while native was stamping
        // `cf` from its OWN independently-fetched copy. Dart and native poll the
        // same CDN file on separate timers, so a config change landing between
        // the two fetches produced a beacon whose `cf` was not the config that
        // produced it — precisely the thing the field is meant to rule out.
        //
        // Snapshotting here, a few lines after the roll, makes `cf` truthful by
        // construction. Native falls back to its own snapshot when this key is
        // absent, so older hosts and native-origin beacons are unaffected.
        'cf':             SamplingManager.instance.getConfigSnapshot(),
      });
    } catch (e) {
      orionPrint('trackFlutterScreen error — $e');
    }
  }

  // ── App Lifecycle ─────────────────────────────────────────────────────────
  //
  // ✅ Fix #15: previously these methods wrapped invokeMethod in
  // Future.microtask, which served no purpose — invokeMethod is already
  // non-blocking, so wrapping it just added a scheduler hop. Now we
  // fire-and-forget directly via unawaited(...) with errors swallowed.
  //
  // The functions still return Future<void> (signature unchanged) but
  // complete synchronously while the channel call proceeds in the background.

  static Future<void> onAppForeground() async {
    if (!isSupported) return;
    // Fire-and-forget — caller doesn't await the channel response.
    _channel.invokeMethod('onAppForeground').catchError((_) => null);
  }

  static Future<void> onAppBackground() async {
    if (!isSupported) return;
    _channel.invokeMethod('onAppBackground').catchError((_) => null);
  }

  static Future<void> onFlutterScreenStart(String screen) async {
    if (!isSupported) return;
    _channel
        .invokeMethod('onFlutterScreenStart', {'screen': screen})
        .catchError((_) => null);
  }

  static Future<void> onFlutterScreenStop(String screen) async {
    if (!isSupported) return;
    _channel
        .invokeMethod('onFlutterScreenStop', {'screen': screen})
        .catchError((_) => null);
  }

  // Kill Switch (1.2.22)
  //
  // Disable/enable the SDK at runtime. While disabled, screen/network/perf
  // beacons are dropped. Crash beacons still report (Android: sendBeaconDirect
  // bypass; iOS: SendData guards only screen/network/perf, crashes go via
  // their own sendBeaconDirect path). Idempotent on both sides — calling
  // disable() when already disabled is a no-op.
  static Future<void> disable() async {
    if (!isSupported) return;
    _channel.invokeMethod('disable').catchError((_) => null);
  }
  static Future<void> enable() async {
    if (!isSupported) return;
    _channel.invokeMethod('enable').catchError((_) => null);
  }

  // ── Sampling Debug ────────────────────────────────────────────────────────

  static int get effectiveSamplingPercent =>
      SamplingManager.instance.getEffectivePercent();

  static bool get isSamplingConfigLoaded =>
      SamplingManager.instance.isConfigLoaded;
}