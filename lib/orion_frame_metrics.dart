import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'orion_logger.dart';

/// Ultra-optimized frame metrics tracker with jank cluster detection
///
/// Features:
/// - Tracks all frames with timestamps
/// - Detects jank clusters (3+ consecutive janky frames)
/// - Returns top 10 worst clusters
/// - Frozen frames tracked separately
/// - Ultra-compact beacon with shorthand names
/// - ✅ NEW: Epoch timestamps for correlation with network waterfall
///
/// Shorthand Key:
/// - sfrm = startFrame
/// - efrm = endFrame
/// - st = startTime (ms from navigation start)
/// - et = endTime (ms from navigation start)
/// - stEp = startEpoch (absolute epoch ms)  ✅ NEW
/// - etEp = endEpoch (absolute epoch ms)    ✅ NEW
/// - avgDur = avgDuration
/// - worstFrmDur = worstFrameDuration
/// - jnkCls = jankClusters
/// - frzFrms = frozenFrames
/// - totFrm = totalFrames
/// - jnkFrm = jankyFrames
/// - frzFrm = frozenFrames
/// - jnkPct = jankyPercentage
class OrionFrameMetrics {
  static final Map<String, _FrameTracker> _trackers = {};

  /// Start tracking frames for a screen
  static void startTracking(String screenName) {
    if (_trackers.containsKey(screenName)) {
      orionPrint("⚠️ Already tracking frames for $screenName");
      return;
    }

    final tracker = _FrameTracker(screenName);
    _trackers[screenName] = tracker;
    tracker.start();

    orionPrint("🎬 Started frame tracking for $screenName");
  }

  /// Stop tracking and return metrics
  static FrameMetricsResult stopTracking(String screenName) {
    final tracker = _trackers.remove(screenName);

    if (tracker == null) {
      orionPrint("⚠️ No tracker found for $screenName");
      return FrameMetricsResult.empty();
    }

    tracker.stop();
    return tracker.getResults();
  }
}

/// Frame metrics result with ultra-compact beacon format
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

  factory FrameMetricsResult.empty() {
    return FrameMetricsResult(
      jankyFrames: 0,
      frozenFrames: 0,
      totalFrames: 0,
      avgFrameDuration: 0.0,
      worstFrameDuration: 0.0,
      top10Clusters: [],
      frozenFramesList: [],
    );
  }

  /// Convert to ultra-compact beacon format with shorthand names
  Map<String, dynamic> toBeacon() {
    return {
      // Summary stats with shorthand
      'totFrm': totalFrames,           // totalFrames
      'jnkFrm': jankyFrames,           // jankyFrames
      'frzFrm': frozenFrames,          // frozenFrames
      'avgDur': avgFrameDuration.toStringAsFixed(2),       // avgFrameDuration
      'worstDur': worstFrameDuration.toStringAsFixed(2),   // worstFrameDuration
      'jnkPct': totalFrames > 0
          ? ((jankyFrames / totalFrames) * 100).toStringAsFixed(2)
          : '0.00',                     // jankyPercentage

      // Top 10 jank clusters (compact)
      'jnkCls': top10Clusters.map((c) => c.toBeacon()).toList(),

      // Frozen frames separate (if any)
      if (frozenFramesList.isNotEmpty)
        'frzFrms': frozenFramesList.map((f) => f.toBeacon()).toList(),
    };
  }
}

/// Jank cluster with shorthand names for beacon
class JankCluster {
  final int id;
  final int startFrame;          // sfrm in beacon
  final int endFrame;            // efrm in beacon
  final int startTime;           // st in beacon (ms from nav start)
  final int endTime;             // et in beacon (ms from nav start)
  final int startEpoch;          // stEp in beacon (absolute epoch ms) ✅ NEW
  final int endEpoch;            // etEp in beacon (absolute epoch ms) ✅ NEW
  final double avgDuration;      // avgDur in beacon
  final double worstDuration;    // worstFrmDur in beacon
  final String buildPhase;       // phase in beacon
  final double severityScore;    // For sorting, not in beacon

  JankCluster({
    required this.id,
    required this.startFrame,
    required this.endFrame,
    required this.startTime,
    required this.endTime,
    required this.startEpoch,    // ✅ NEW
    required this.endEpoch,      // ✅ NEW
    required this.avgDuration,
    required this.worstDuration,
    required this.buildPhase,
    required this.severityScore,
  });

  /// Convert to ultra-compact beacon format
  /// Frontend can calculate:
  /// - jankyFrameCount = efrm - sfrm + 1
  /// - severity from avgDur and worstFrmDur
  /// - duration = et - st
  ///
  /// ✅ NEW: stEp/etEp for correlation with network waterfall
  Map<String, dynamic> toBeacon() {
    return {
      'id': id,
      'sfrm': startFrame,              // startFrame
      'efrm': endFrame,                // endFrame
      'st': startTime,                 // startTime (ms from nav)
      'et': endTime,                   // endTime (ms from nav)
      'stEp': startEpoch,              // ✅ NEW: startEpoch (absolute ms)
      'etEp': endEpoch,                // ✅ NEW: endEpoch (absolute ms)
      'avgDur': avgDuration.toStringAsFixed(2),        // avgDuration
      'worstFrmDur': worstDuration.toStringAsFixed(2), // worstFrameDuration
      'phase': buildPhase,             // buildPhase
    };
  }

  /// Frame count (calculated, not stored)
  int get frameCount => endFrame - startFrame + 1;
}

/// Frozen frame with shorthand names
class FrozenFrame {
  final int frameNumber;      // frm in beacon
  final int timestamp;        // ts in beacon (ms from nav start)
  final int epoch;            // ep in beacon (absolute ms) ✅ NEW
  final double duration;      // dur in beacon
  final String buildPhase;    // phase in beacon

  FrozenFrame({
    required this.frameNumber,
    required this.timestamp,
    required this.epoch,       // ✅ NEW
    required this.duration,
    required this.buildPhase,
  });

  /// Convert to ultra-compact beacon format
  Map<String, dynamic> toBeacon() {
    return {
      'frm': frameNumber,                    // frameNumber
      'ts': timestamp,                       // timestamp (ms from nav)
      'ep': epoch,                           // ✅ NEW: epoch (absolute ms)
      'dur': duration.toStringAsFixed(2),    // duration
      'phase': buildPhase,                   // buildPhase
    };
  }
}

/// Internal frame timestamp (in-memory only, not in beacon)
class _FrameTimestamp {
  final int frameNumber;
  final int timestamp;        // ms from navigation start
  final int epoch;            // ✅ NEW: absolute epoch ms
  final double duration;
  final bool isJanky;
  final bool isFrozen;
  final String buildPhase;

  _FrameTimestamp({
    required this.frameNumber,
    required this.timestamp,
    required this.epoch,       // ✅ NEW
    required this.duration,
    required this.isJanky,
    required this.isFrozen,
    required this.buildPhase,
  });
}

/// Internal frame tracker
class _FrameTracker {
  final String screenName;

  // Track all frames in memory (not sent in beacon)
  final List<_FrameTimestamp> _allFrames = [];
  final List<FrozenFrame> _frozenFrames = [];

  // Timing
  final Stopwatch _stopwatch = Stopwatch();
  int? _lastFrameTime;
  bool _isTracking = false;

  // ✅ NEW: Track navigation start epoch for absolute timestamps
  late int _navigationStartEpoch;

  // Thresholds (in milliseconds)
  static const double _jankyThreshold = 16.67;  // >16.67ms = janky
  static const double _frozenThreshold = 700.0; // >700ms = frozen

  _FrameTracker(this.screenName);

  void start() {
    _isTracking = true;
    _lastFrameTime = null;

    // ✅ NEW: Capture navigation start epoch
    _navigationStartEpoch = DateTime.now().millisecondsSinceEpoch;

    _stopwatch.start();

    // Register frame callback
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
    if (!_isTracking) return;

    final currentTime = timestamp.inMilliseconds;

    if (_lastFrameTime != null) {
      final frameDuration = (currentTime - _lastFrameTime!).toDouble();

      // Calculate frame START time (when frame began)
      final currentStopwatchTime = _stopwatch.elapsedMilliseconds;
      final frameTimestamp = (currentStopwatchTime - frameDuration.toInt()).clamp(0, currentStopwatchTime);

      // ✅ NEW: Calculate absolute epoch for this frame
      final frameEpoch = _navigationStartEpoch + frameTimestamp;

      final isJanky = frameDuration > _jankyThreshold;
      final isFrozen = frameDuration > _frozenThreshold;
      final buildPhase = _getCurrentBuildPhase();

      // Track frame with timestamp
      _allFrames.add(_FrameTimestamp(
        frameNumber: _allFrames.length + 1,
        timestamp: frameTimestamp,
        epoch: frameEpoch,             // ✅ NEW
        duration: frameDuration,
        isJanky: isJanky,
        isFrozen: isFrozen,
        buildPhase: buildPhase,
      ));

      // Track frozen frames separately
      if (isFrozen) {
        _frozenFrames.add(FrozenFrame(
          frameNumber: _allFrames.length,
          timestamp: frameTimestamp,
          epoch: frameEpoch,           // ✅ NEW
          duration: frameDuration,
          buildPhase: buildPhase,
        ));
      }
    }

    _lastFrameTime = currentTime;

    // Schedule next frame
    _scheduleNextFrame();
  }

  String _getCurrentBuildPhase() {
    final phase = SchedulerBinding.instance.schedulerPhase;

    switch (phase) {
      case SchedulerPhase.idle:
        return 'idle';
      case SchedulerPhase.transientCallbacks:
        return 'animation';
      case SchedulerPhase.midFrameMicrotasks:
        return 'microtasks';
      case SchedulerPhase.persistentCallbacks:
        return 'build';
      case SchedulerPhase.postFrameCallbacks:
        return 'postFrame';
      default:
        return 'unknown';
    }
  }

  FrameMetricsResult getResults() {
    // Calculate summary stats
    final jankyFrames = _allFrames.where((f) => f.isJanky).length;
    final frozenFramesCount = _frozenFrames.length;
    final totalFrames = _allFrames.length;

    final avgDuration = _allFrames.isEmpty
        ? 0.0
        : _allFrames.map((f) => f.duration).reduce((a, b) => a + b) / _allFrames.length;

    final worstDuration = _allFrames.isEmpty
        ? 0.0
        : _allFrames.map((f) => f.duration).reduce((a, b) => a > b ? a : b);

    // Detect jank clusters
    final allClusters = _detectJankClusters();

    // Select top 10 worst clusters
    final top10Clusters = _selectTop10Clusters(allClusters);

    // Log summary
    orionPrint(
        "📊 [$screenName] Frame Metrics:\n"
            "   Total: $totalFrames frames\n"
            "   Janky: $jankyFrames (${_getPercentage(jankyFrames, totalFrames)}%)\n"
            "   Frozen: $frozenFramesCount\n"
            "   Avg: ${avgDuration.toStringAsFixed(2)}ms\n"
            "   Worst: ${worstDuration.toStringAsFixed(2)}ms\n"
            "   Clusters detected: ${allClusters.length}\n"
            "   Top 10 clusters: ${top10Clusters.length}"
    );

    // Log top 3 clusters
    if (top10Clusters.isNotEmpty) {
      orionPrint("🐌 Top jank clusters for $screenName:");
      for (var i = 0; i < top10Clusters.length && i < 3; i++) {
        final cluster = top10Clusters[i];
        orionPrint(
            "   Cluster #${cluster.id}: Frames ${cluster.startFrame}-${cluster.endFrame} "
                "(${cluster.startTime}-${cluster.endTime}ms) - "
                "Worst: ${cluster.worstDuration.toStringAsFixed(2)}ms"
        );
      }
    }

    return FrameMetricsResult(
      jankyFrames: jankyFrames,
      frozenFrames: frozenFramesCount,
      totalFrames: totalFrames,
      avgFrameDuration: avgDuration,
      worstFrameDuration: worstDuration,
      top10Clusters: top10Clusters,
      frozenFramesList: _frozenFrames,
    );
  }

  /// Detect jank clusters (3+ consecutive janky frames)
  List<JankCluster> _detectJankClusters() {
    final clusters = <JankCluster>[];
    List<_FrameTimestamp> currentCluster = [];
    int clusterId = 1;

    for (var i = 0; i < _allFrames.length; i++) {
      final frame = _allFrames[i];

      if (frame.isJanky) {
        // Add to current cluster
        currentCluster.add(frame);
      } else {
        // End of cluster - check if valid (3+ frames)
        if (currentCluster.length >= 3) {
          clusters.add(_createCluster(currentCluster, clusterId++));
        }
        currentCluster = [];
      }
    }

    // Check last cluster
    if (currentCluster.length >= 3) {
      clusters.add(_createCluster(currentCluster, clusterId));
    }

    return clusters;
  }

  /// Create cluster from frame list
  JankCluster _createCluster(List<_FrameTimestamp> frames, int id) {
    final startFrame = frames.first.frameNumber;
    final endFrame = frames.last.frameNumber;
    final startTime = frames.first.timestamp;
    final endTime = frames.last.timestamp + frames.last.duration.toInt();

    // ✅ NEW: Calculate epoch timestamps for cluster
    final startEpoch = frames.first.epoch;
    final endEpoch = frames.last.epoch + frames.last.duration.toInt();

    final avgDuration = frames.map((f) => f.duration).reduce((a, b) => a + b) / frames.length;
    final worstDuration = frames.map((f) => f.duration).reduce((a, b) => a > b ? a : b);

    // Get most common build phase
    final phases = frames.map((f) => f.buildPhase).toList();
    final buildPhase = _getMostCommon(phases);

    // Calculate severity score for sorting
    final severityScore = _calculateSeverityScore(
      startFrame: startFrame,
      frameCount: frames.length,
      avgDuration: avgDuration,
      worstDuration: worstDuration,
    );

    return JankCluster(
      id: id,
      startFrame: startFrame,
      endFrame: endFrame,
      startTime: startTime,
      endTime: endTime,
      startEpoch: startEpoch,    // ✅ NEW
      endEpoch: endEpoch,        // ✅ NEW
      avgDuration: avgDuration,
      worstDuration: worstDuration,
      buildPhase: buildPhase,
      severityScore: severityScore,
    );
  }

  /// Calculate severity score for cluster prioritization
  /// Higher score = worse cluster = higher priority
  double _calculateSeverityScore({
    required int startFrame,
    required int frameCount,
    required double avgDuration,
    required double worstDuration,
  }) {
    // Formula: (avgDur × 0.3) + (worstDur × 0.4) + (frameCount × 5) + (early bonus)

    final avgWeight = avgDuration * 0.3;
    final worstWeight = worstDuration * 0.4;
    final countWeight = frameCount * 5.0;

    // Early clusters (first 10 frames) get bonus - critical for UX
    final earlyBonus = startFrame <= 10 ? 20.0 : 0.0;

    return avgWeight + worstWeight + countWeight + earlyBonus;
  }

  /// Select top 10 worst clusters by severity score
  List<JankCluster> _selectTop10Clusters(List<JankCluster> allClusters) {
    // Sort by severity score (worst first)
    allClusters.sort((a, b) => b.severityScore.compareTo(a.severityScore));

    // Take top 10
    return allClusters.take(10).toList();
  }

  String _getMostCommon(List<String> items) {
    if (items.isEmpty) return 'unknown';

    final counts = <String, int>{};
    for (var item in items) {
      counts[item] = (counts[item] ?? 0) + 1;
    }

    return counts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  String _getPercentage(int part, int total) {
    if (total == 0) return '0.0';
    return ((part / total) * 100).toStringAsFixed(1);
  }
}