import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'orion_flutter_platform_interface.dart';
import 'orion_sampling_manager.dart';
import 'orion_http_overrides.dart';

export 'orion_wake_lock.dart';
export 'orion_rage_click_tracker.dart';
export 'orion_rage_click_detector.dart';
export 'orion_http_overrides.dart';

class OrionFlutter {
  static const MethodChannel _channel = MethodChannel('orion_flutter');

  static bool _isReportingError = false;
  static String? _lastException;
  static DateTime? _lastErrorTime;

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

      return await _channel.invokeMethod<String>('initializeEdOrion', {
        'cid': cid,
        'pid': pid,
      });
    } catch (e) {
      debugPrint('[Orion] initializeEdOrion error — $e');
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

  static Future<void> trackFlutterErrorRaw({
    required String exception,
    required String stack,
    String? library,
    String? context,
    String? screen,
    List<Map<String, dynamic>>? network,
  }) async {
    if (!isSupported || _isReportingError) return;

    if (_lastException == exception &&
        _lastErrorTime != null &&
        DateTime.now().difference(_lastErrorTime!) < const Duration(seconds: 10)) {
      return;
    }

    _isReportingError = true;
    _lastException    = exception;
    _lastErrorTime    = DateTime.now();

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
        debugPrint('[Orion] Beacon dropped by sampling '
            '(effective: ${SamplingManager.instance.getEffectivePercent()}%)');
        return;
      }

      // ✅ Verbose beacon preview is guarded by kDebugMode so it never runs
      //    in production, avoiding the cost of JsonEncoder.withIndent on every
      //    screen transition.
      if (kDebugMode) {
        debugPrint(
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
      });
    } catch (e) {
      debugPrint('[Orion] trackFlutterScreen error — $e');
    }
  }

  // ── App Lifecycle ─────────────────────────────────────────────────────────

  static Future<void> onAppForeground() async {
    if (!isSupported) return;
    Future.microtask(() async {
      try { await _channel.invokeMethod('onAppForeground'); } catch (_) {}
    });
  }

  static Future<void> onAppBackground() async {
    if (!isSupported) return;
    Future.microtask(() async {
      try { await _channel.invokeMethod('onAppBackground'); } catch (_) {}
    });
  }

  static Future<void> onFlutterScreenStart(String screen) async {
    if (!isSupported) return;
    Future.microtask(() async {
      try {
        await _channel.invokeMethod('onFlutterScreenStart', {'screen': screen});
      } catch (_) {}
    });
  }

  static Future<void> onFlutterScreenStop(String screen) async {
    if (!isSupported) return;
    Future.microtask(() async {
      try {
        await _channel.invokeMethod('onFlutterScreenStop', {'screen': screen});
      } catch (_) {}
    });
  }

  // ── Sampling Debug ────────────────────────────────────────────────────────

  static int get effectiveSamplingPercent =>
      SamplingManager.instance.getEffectivePercent();

  static bool get isSamplingConfigLoaded =>
      SamplingManager.instance.isConfigLoaded;
}
