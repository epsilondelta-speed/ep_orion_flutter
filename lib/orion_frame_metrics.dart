import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'orion_logger.dart';
import 'orion_sampling_manager.dart';

/// Ultra-optimized frame metrics tracker with jank cluster detection.
///
/// Sampling kill-switch: startTracking() is a no-op when
/// SamplingManager.instance.isTrackingEnabled is false, so no frame callbacks
/// are registered and no memory is allocated for frame data.
///
/// Memory cap: _allFrames is capped at _maxFrames (2 000 entries ≈ 33 s at
/// 60 fps). Frames beyond the cap are silently dropped so a very long screen
/// session cannot cause unbounded growth.
class OrionFrameMetrics {
  static final Map<String, _FrameTracker> _trackers = {};

  /// Start tracking frames for a screen.
  /// No-op when the sampling kill-switch is active.
  static void startTracking(String screenName) {
    try {
      // ✅ Sampling kill-switch: skip frame collection when disabled.
      if (!SamplingManager.instance.isTrackingEnabled) return;

      if (_trackers.containsKey(screenName)) {
        orionPrint('⚠️ Already tracking frames for $screenName');
        return;
      }

      final tracker = _FrameTracker(screenName);
      _trackers[screenName] = tracker;
      tracker.start();

      orionPrint('🎬 Started frame tracking for $screenName');
    } catch (e) {
      orionPrint('⚠️ OrionFrameMetrics: startTracking error (ignored): $e');
    }
  }

  /// Stop tracking and return metrics. Returns empty result on error.
  static FrameMetricsResult stopTracking(String screenName) {
    try {
      final tracker = _trackers.remove(screenName);

      if (tracker == null) {
        orionPrint('⚠️ No tracker found for $screenName');
        return FrameMetricsResult.empty();
      }

      tracker.stop();
      return tracker.getResults();
    } catch (e) {
      orionPrint('⚠️ OrionFrameMetrics: stopTracking error (ignored): $e');
      return FrameMetricsResult.empty();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public result types (unchanged API surface)
// ─────────────────────────────────────────────────────────────────────────────

class FrameMetricsResult {
  final int jankyFrames;
  final int frozenFrames;
  final int totalFrames;
  final double avgFrameDuration;
  final double worstFrameDuration;
  final List<JankCluster> top10Clusters;
  final List<FrozenFrame> frozenFramesList;

  FrameMetricsResult({
    required this.jankyFrames,
    required this.frozenFrames,
    required this.totalFrames,
    required this.avgFrameDuration,
    required this.worstFrameDuration,
    required this.top10Clusters,
    required this.frozenFramesList,
  });

  factory FrameMetricsResult.empty() => FrameMetricsResult(
        jankyFrames: 0,
        frozenFrames: 0,
        totalFrames: 0,
        avgFrameDuration: 0.0,
        worstFrameDuration: 0.0,
        top10Clusters: [],
        frozenFramesList: [],
      );

  Map<String, dynamic> toBeacon() {
    return {
      'totFrm':  totalFrames,
      'jnkFrm':  jankyFrames,
      'frzFrm':  frozenFrames,
      'avgDur':  avgFrameDuration.toStringAsFixed(2),
      'worstDur': worstFrameDuration.toStringAsFixed(2),
      'jnkPct':  totalFrames > 0
          ? ((jankyFrames / totalFrames) * 100).toStringAsFixed(2)
          : '0.00',
      'jnkCls':  top10Clusters.map((c) => c.toBeacon()).toList(),
      if (frozenFramesList.isNotEmpty)
        'frzFrms': frozenFramesList.map((f) => f.toBeacon()).toList(),
    };
  }
}

class JankCluster {
  final int id;
  final int startFrame;
  final int endFrame;
  final int startTime;
  final int endTime;
  final int startEpoch;
  final int endEpoch;
  final double avgDuration;
  final double worstDuration;
  final String buildPhase;
  final double severityScore;

  JankCluster({
    required this.id,
    required this.startFrame,
    required this.endFrame,
    required this.startTime,
    required this.endTime,
    required this.startEpoch,
    required this.endEpoch,
    required this.avgDuration,
    required this.worstDuration,
    required this.buildPhase,
    required this.severityScore,
  });

  Map<String, dynamic> toBeacon() => {
        'id':          id,
        'sfrm':        startFrame,
        'efrm':        endFrame,
        'st':          startTime,
        'et':          endTime,
        'stEp':        startEpoch,
        'etEp':        endEpoch,
        'avgDur':      avgDuration.toStringAsFixed(2),
        'worstFrmDur': worstDuration.toStringAsFixed(2),
        'phase':       buildPhase,
      };

  int get frameCount => endFrame - startFrame + 1;
}

class FrozenFrame {
  final int frameNumber;
  final int timestamp;
  final int epoch;
  final double duration;
  final String buildPhase;

  FrozenFrame({
    required this.frameNumber,
    required this.timestamp,
    required this.epoch,
    required this.duration,
    required this.buildPhase,
  });

  Map<String, dynamic> toBeacon() => {
        'frm':   frameNumber,
        'ts':    timestamp,
        'ep':    epoch,
        'dur':   duration.toStringAsFixed(2),
        'phase': buildPhase,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal types
// ─────────────────────────────────────────────────────────────────────────────

class _FrameTimestamp {
  final int frameNumber;
  final int timestamp;
  final int epoch;
  final double duration;
  final bool isJanky;
  final bool isFrozen;
  final String buildPhase;

  _FrameTimestamp({
    required this.frameNumber,
    required this.timestamp,
    required this.epoch,
    required this.duration,
    required this.isJanky,
    required this.isFrozen,
    required this.buildPhase,
  });
}

class _FrameTracker {
  final String screenName;

  final List<_FrameTimestamp> _allFrames   = [];
  final List<FrozenFrame>     _frozenFrames = [];

  // ✅ Memory cap: at 60 fps, 2 000 frames ≈ 33 seconds of tracking.
  // Frames beyond this limit are silently dropped so a long session
  // never causes unbounded list growth.
  static const int _maxFrames = 2000;

  final Stopwatch _stopwatch = Stopwatch();
  int? _lastFrameTime;
  bool _isTracking = false;
  late int _navigationStartEpoch;

  static const double _jankyThreshold  = 16.67;
  static const double _frozenThreshold = 700.0;

  _FrameTracker(this.screenName);

  void start() {
    _isTracking           = true;
    _lastFrameTime        = null;
    _navigationStartEpoch = DateTime.now().millisecondsSinceEpoch;
    _stopwatch.start();
    _scheduleNextFrame();
  }

  void stop() {
    _isTracking = false;
    _stopwatch.stop();
  }

  void _scheduleNextFrame() {
    if (_isTracking) {
      SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
    }
  }

  void _onFrame(Duration timestamp) {
    try {
      if (!_isTracking) return;

      final currentTime = timestamp.inMilliseconds;

      if (_lastFrameTime != null) {
        // ✅ Memory cap: once we hit _maxFrames, stop accumulating frame data.
        if (_allFrames.length >= _maxFrames) {
          // Keep scheduling so stop() can be called cleanly, but don't store.
          _lastFrameTime = currentTime;
          _scheduleNextFrame();
          return;
        }

        final frameDuration = (currentTime - _lastFrameTime!).toDouble();
        final currentStopwatchTime = _stopwatch.elapsedMilliseconds;
        final frameTimestamp = (currentStopwatchTime - frameDuration.toInt())
            .clamp(0, currentStopwatchTime);
        final frameEpoch    = _navigationStartEpoch + frameTimestamp;
        final isJanky       = frameDuration > _jankyThreshold;
        final isFrozen      = frameDuration > _frozenThreshold;
        final buildPhase    = _getCurrentBuildPhase();

        _allFrames.add(_FrameTimestamp(
          frameNumber: _allFrames.length + 1,
          timestamp:   frameTimestamp,
          epoch:       frameEpoch,
          duration:    frameDuration,
          isJanky:     isJanky,
          isFrozen:    isFrozen,
          buildPhase:  buildPhase,
        ));

        if (isFrozen) {
          _frozenFrames.add(FrozenFrame(
            frameNumber: _allFrames.length,
            timestamp:   frameTimestamp,
            epoch:       frameEpoch,
            duration:    frameDuration,
            buildPhase:  buildPhase,
          ));
        }
      }

      _lastFrameTime = currentTime;
      _scheduleNextFrame();
    } catch (e) {
      // Never let frame callback errors propagate to the Flutter scheduler.
      _isTracking = false;
    }
  }

  String _getCurrentBuildPhase() {
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      switch (phase) {
        case SchedulerPhase.idle:               return 'idle';
        case SchedulerPhase.transientCallbacks:  return 'animation';
        case SchedulerPhase.midFrameMicrotasks:  return 'microtasks';
        case SchedulerPhase.persistentCallbacks: return 'build';
        case SchedulerPhase.postFrameCallbacks:  return 'postFrame';
        default:                                 return 'unknown';
      }
    } catch (_) {
      return 'unknown';
    }
  }

  FrameMetricsResult getResults() {
    try {
      final jankyFrames      = _allFrames.where((f) => f.isJanky).length;
      final frozenFramesCount = _frozenFrames.length;
      final totalFrames      = _allFrames.length;

      final avgDuration = _allFrames.isEmpty
          ? 0.0
          : _allFrames.map((f) => f.duration).reduce((a, b) => a + b) /
              _allFrames.length;

      final worstDuration = _allFrames.isEmpty
          ? 0.0
          : _allFrames.map((f) => f.duration).reduce((a, b) => a > b ? a : b);

      final allClusters  = _detectJankClusters();
      final top10Clusters = _selectTop10Clusters(allClusters);

      if (kDebugMode) {
        orionPrint(
          '📊 [$screenName] Frames: $totalFrames total, $jankyFrames janky, '
          '$frozenFramesCount frozen, avg=${avgDuration.toStringAsFixed(2)}ms',
        );
      }

      return FrameMetricsResult(
        jankyFrames:       jankyFrames,
        frozenFrames:      frozenFramesCount,
        totalFrames:       totalFrames,
        avgFrameDuration:  avgDuration,
        worstFrameDuration: worstDuration,
        top10Clusters:     top10Clusters,
        frozenFramesList:  _frozenFrames,
      );
    } catch (e) {
      orionPrint('⚠️ OrionFrameMetrics: getResults error: $e');
      return FrameMetricsResult.empty();
    }
  }

  List<JankCluster> _detectJankClusters() {
    final clusters       = <JankCluster>[];
    List<_FrameTimestamp> currentCluster = [];
    int clusterId        = 1;

    for (final frame in _allFrames) {
      if (frame.isJanky) {
        currentCluster.add(frame);
      } else {
        if (currentCluster.length >= 3) {
          clusters.add(_createCluster(currentCluster, clusterId++));
        }
        currentCluster = [];
      }
    }
    if (currentCluster.length >= 3) {
      clusters.add(_createCluster(currentCluster, clusterId));
    }
    return clusters;
  }

  JankCluster _createCluster(List<_FrameTimestamp> frames, int id) {
    final avgDuration   = frames.map((f) => f.duration).reduce((a, b) => a + b) / frames.length;
    final worstDuration = frames.map((f) => f.duration).reduce((a, b) => a > b ? a : b);
    final phases        = frames.map((f) => f.buildPhase).toList();

    return JankCluster(
      id:            id,
      startFrame:    frames.first.frameNumber,
      endFrame:      frames.last.frameNumber,
      startTime:     frames.first.timestamp,
      endTime:       frames.last.timestamp + frames.last.duration.toInt(),
      startEpoch:    frames.first.epoch,
      endEpoch:      frames.last.epoch + frames.last.duration.toInt(),
      avgDuration:   avgDuration,
      worstDuration: worstDuration,
      buildPhase:    _getMostCommon(phases),
      severityScore: _calculateSeverityScore(
        startFrame:    frames.first.frameNumber,
        frameCount:    frames.length,
        avgDuration:   avgDuration,
        worstDuration: worstDuration,
      ),
    );
  }

  double _calculateSeverityScore({
    required int startFrame,
    required int frameCount,
    required double avgDuration,
    required double worstDuration,
  }) {
    final earlyBonus = startFrame <= 10 ? 20.0 : 0.0;
    return (avgDuration * 0.3) + (worstDuration * 0.4) + (frameCount * 5.0) + earlyBonus;
  }

  List<JankCluster> _selectTop10Clusters(List<JankCluster> all) {
    all.sort((a, b) => b.severityScore.compareTo(a.severityScore));
    return all.take(10).toList();
  }

  String _getMostCommon(List<String> items) {
    if (items.isEmpty) return 'unknown';
    final counts = <String, int>{};
    for (final item in items) {
      counts[item] = (counts[item] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }
}
