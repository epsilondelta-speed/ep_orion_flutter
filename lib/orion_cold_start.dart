import 'dart:io';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'orion_logger.dart';

/// Dart-side cold-start marks (1.2.26).
///
/// Two responsibilities, both single-shot per process:
///   1. Mark the first Flutter frame  → native stamps elapsedRealtime.
///   2. Mark the first NON-Orion network response → native stamps it.
///
/// Design constraints honoured throughout:
///   - Zero threads, zero timers, zero retained state beyond three bools.
///   - Every path try-caught; a failure means an absent phase, never a
///     crash and never a slow frame.
///   - Channel calls are fire-and-forget (not awaited) so they can never
///     delay the frame pipeline or a network callback.
///   - If the scheduler binding isn't initialized when armed (client called
///     init before ensureInitialized), we skip silently — phase absent.
class OrionColdStart {
  OrionColdStart._();

  static const MethodChannel _channel = MethodChannel('orion_flutter');

  static bool _armed = false;
  static bool _firstFrameMarked = false;
  static bool _firstNetMarked = false;

  /// Substrings identifying Orion's own traffic — excluded from
  /// firstNetworkResponse so we measure the app's network, not ours.
  static const List<String> _orionInternalHosts = [
    'ed-sys.net',
    'cdn.epsilondelta.co',
  ];

  /// Arm the first-frame mark. Called once from initializeEdOrion().
  /// Safe to call multiple times; only the first arms.
  /// Android-only for now — the iOS native side has no cold-start tracker
  /// yet, so we skip entirely rather than hit notImplemented on the channel.
  static void armFirstFrameMark() {
    if (_armed) return;
    if (!Platform.isAndroid) return;
    _armed = true;
    try {
      // If the binding isn't up yet this throws — swallowed, phase absent.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_firstFrameMarked) return;
        _firstFrameMarked = true;
        try {
          // Fire-and-forget: never await inside a frame callback.
          _channel
              .invokeMethod('coldStartMarkFirstFrame')
              .catchError((_) => null);
        } catch (_) {}
      });
    } catch (e) {
      orionPrint('[OrionColdStart] first-frame arm skipped: $e');
    }
  }

  /// Report a completed network response. Call from network tracking paths
  /// (OrionHttpOverrides / Dio interceptor) — this method self-filters and
  /// self-disarms, so callers just call it unconditionally; after the first
  /// non-Orion hit it is a single boolean check.
  static void maybeMarkFirstNetwork(String url) {
    if (_firstNetMarked) return;
    if (!Platform.isAndroid) return;
    try {
      final lower = url.toLowerCase();
      for (final host in _orionInternalHosts) {
        if (lower.contains(host)) return; // Orion's own traffic — ignore.
      }
      _firstNetMarked = true;
      _channel
          .invokeMethod('coldStartMarkFirstNetworkResponse')
          .catchError((_) => null);
    } catch (_) {
      // Never let cold-start marking interfere with network tracking.
    }
  }
}
