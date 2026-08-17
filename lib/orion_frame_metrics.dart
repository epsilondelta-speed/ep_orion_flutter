import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'orion_logger.dart';
import 'orion_sampling_manager.dart';

/// Ultra-optimized frame metrics tracker with jank cluster detection.
///
/// ─────────────────────────────────────────────────────────────────────────
/// 1.2.32 — PASSIVE OBSERVATION (was: forced render loop)
/// ─────────────────────────────────────────────────────────────────────────
///
/// This tracker previously measured frames by re-registering itself as a
/// transient frame callback after every frame:
///
///     SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
///
/// `scheduleFrameCallback` takes a `scheduleNewFrame` parameter that defaults
/// to true, and its first statement is `scheduleFrame()`. Registering the
/// callback therefore REQUESTED A VSYNC — and because the callback
/// re-registered itself, the SDK held the engine in a permanent render loop
/// for as long as any tracked screen was visible. Flutter normally renders
/// only when something is dirty; an idle screen costs nothing. With the old
/// tracker, an idle screen cost a full pipeline flush and a raster submission
/// every 16 ms, forever. The loop also continued after the `_maxFrames` cap
/// was reached, forcing frames it did not even record.
///
/// Two further consequences of that design, both now fixed:
///
///   • The measurement was self-contaminating. `frameDuration` was the delta
///     between consecutive callbacks, which only approximates frame cost
///     BECAUSE the SDK forced a callback every vsync. Any pause in engine
///     frame production (backgrounding in particular) was recorded as one
///     enormous frame — the source of the multi-second `worstDur` values
///     seen in production.
///
///   • `timestamp.inMilliseconds` TRUNCATES. At 60 Hz, vsync lands every
///     16 667 µs, so integer deltas ran 16, 17, 17, 16, 17, 17 … against a
///     16.67 ms threshold — two of every three healthy frames were counted
///     as jank. At 90 Hz (11, 11, 11 …) and 120 Hz (8, 8, 9 …) nothing ever
///     cleared the bar. 60 Hz devices floored near 67 % jank while
///     high-refresh devices floored near 0 %.
///
/// The tracker now uses `SchedulerBinding.addTimingsCallback`, which reports
/// `FrameTiming` records for frames the app ACTUALLY rendered, with
/// microsecond precision and no scheduling side effect. Idle screens produce
/// no timings and no work.
///
/// BEACON CONTRACT: unchanged. Every key and type the pipeline consumes
/// (`totFrm`, `jnkFrm`, `frzFrm`, `jnkPct`, `avgDur`, `worstDur`, `jnkCls`
/// with `sfrm`/`efrm`/`worstFrmDur`) is emitted exactly as before, and the
/// cluster detection algorithm is untouched. Three additive keys are new:
/// `frmSrc`, `refHz`, `jnkFrmR` — consumers ignore unknown keys.
///
/// EXPECTED DATA SHIFT AT ROLLOUT (this is the fix working, not a regression):
///   totFrm    falls sharply — idle vsyncs are no longer counted as frames
///   jnkPct    becomes real; the ~67 % truncation floor on 60 Hz disappears
///   worstDur  multi-second background-gap artifacts disappear
///   frzFrm %  RISES — the consumer divides frzFrm by totFrm, and that
///             denominator is no longer inflated by forced frames
/// `frmSrc: "timings"` is absent on all pre-1.2.32 beacons, so the backend
/// can split the two regimes cleanly.
///
/// Sampling kill-switch: startTracking() is a no-op when
/// SamplingManager.instance.isTrackingEnabled is false, so no timings callback
/// is registered and no memory is allocated for frame data.
///
/// Memory cap: _allFrames is capped at a refresh-rate-aware limit — 600 frames
/// on 60 Hz devices and 1000 on >60 Hz devices. Because frames are now only
/// real rendered frames, this covers a much longer wall-clock window than it
/// did before. On reaching the cap the tracker DEREGISTERS its callback
/// entirely rather than continuing to listen.
///
/// Jank cluster cap: at most _maxClusters (50) clusters are retained per
/// beacon. Selection is by severity score so the most impactful clusters
/// always survive even when many are detected.
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

  /// Frames that missed THIS device's own frame budget (1000 / refreshHz),
  /// as opposed to [jankyFrames] which uses the fixed 16.67 ms bar.
  ///
  /// Emitted as the additive `jnkFrmR` key. `jnkFrm` / `jnkPct` deliberately
  /// stay on the fixed bar so every existing chart and all 32 aggregation
  /// dimensions keep their meaning; this field exists so high-refresh
  /// regressions — a 120 Hz device stuttering to 70 fps, entirely invisible
  /// against a 16.67 ms threshold — can be evaluated without another SDK
  /// release.
  final int jankyFramesRefreshAware;

  /// Display refresh rate in Hz, rounded. Emitted as `refHz` so the backend
  /// can interpret [jankyFramesRefreshAware] and segment by device class.
  final int refreshHz;

  FrameMetricsResult({
    required this.jankyFrames,
    required this.frozenFrames,
    required this.totalFrames,
    required this.avgFrameDuration,
    required this.worstFrameDuration,
    required this.top10Clusters,
    required this.frozenFramesList,
    this.jankyFramesRefreshAware = 0,
    this.refreshHz = 60,
  });

  factory FrameMetricsResult.empty() => FrameMetricsResult(
    jankyFrames: 0,
    frozenFrames: 0,
    totalFrames: 0,
    avgFrameDuration: 0.0,
    worstFrameDuration: 0.0,
    top10Clusters: [],
    frozenFramesList: [],
    jankyFramesRefreshAware: 0,
    refreshHz: 60,
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

      // ── Additive keys (1.2.32) ───────────────────────────────────────────
      // Unknown keys are ignored by gemconsumer (which stores frameMetrics
      // verbatim) and by fiveMinFrameAgg.py (which reads by key name), so
      // these are safe to ship ahead of any backend work.
      //
      // frmSrc marks which measurement regime produced this beacon. Absent on
      // every pre-1.2.32 beacon, so `WHERE frmSrc IS NULL` isolates the old
      // forced-render-loop data whose totFrm and jnkPct are not comparable.
      'frmSrc':  'timings',
      'refHz':   refreshHz,
      'jnkFrmR': jankyFramesRefreshAware,
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
  /// Missed this device's own budget (1000 / refreshHz). Feeds `jnkFrmR`.
  final bool isJankyRefreshAware;
  final bool isFrozen;
  final String buildPhase;

  _FrameTimestamp({
    required this.frameNumber,
    required this.timestamp,
    required this.epoch,
    required this.duration,
    required this.isJanky,
    required this.isJankyRefreshAware,
    required this.isFrozen,
    required this.buildPhase,
  });
}

class _FrameTracker {
  final String screenName;

  final List<_FrameTimestamp> _allFrames   = [];
  final List<FrozenFrame>     _frozenFrames = [];

  // ✅ Memory cap: bounds the retained per-frame buffer so a long session
  // never causes unbounded list growth. The cap is refresh-rate aware:
  //   - 60 Hz devices  → 600 frames  (~10 s of tracking)
  //   - >60 Hz devices → 1000 frames (~10 s at 90 Hz, ~8.3 s at 120 Hz)
  // A fixed frame count would give high-refresh devices a much shorter time
  // window (600 frames = only 5 s at 120 Hz), so we raise the cap on those
  // devices to keep the captured *duration* roughly comparable. Resolved once
  // in start() from the device refresh rate. Lowered from a flat 5000 in
  // 1.2.26 — the retained frames only feed summary metrics and contiguous
  // jank-cluster detection, neither of which needs a long history.
  static const int _maxFrames60Hz   = 600;
  static const int _maxFramesHighHz  = 1000;
  static const double _highRefreshThreshold = 61.0; // Hz; >60 counts as high-refresh
  int _maxFrames = _maxFrames60Hz; // resolved in start()

  /// Display refresh rate, resolved once in start(). Reported as `refHz`.
  int _refreshHz = 60;

  /// This device's own per-frame budget in ms (1000 / refreshHz). Drives the
  /// additive `jnkFrmR` count only — `jnkFrm` stays on _jankyThreshold so the
  /// existing dashboards and aggregation dimensions keep their meaning.
  double _refreshBudgetMs = 16.67;

  // ✅ Cluster cap: at most _maxClusters jank clusters are emitted per
  // beacon, selected by severity score. Bumped from 10 to 50 in 1.2.24 to
  // give heavy/long-dwell screens more diagnostic visibility while still
  // bounding beacon size.
  static const int _maxClusters = 50;

  final Stopwatch _stopwatch = Stopwatch();
  bool _isTracking = false;
  /// Whether our timings callback is currently registered. Kept separate from
  /// _isTracking because we deregister early on reaching _maxFrames, and
  /// removeTimingsCallback asserts the callback is present.
  bool _listening = false;
  late int _navigationStartEpoch;

  static const double _jankyThreshold  = 16.67;
  static const double _frozenThreshold = 700.0;

  /// Maximum tolerated disagreement between FramePhase.rasterFinishWallTime
  /// and DateTime.now() before we stop trusting it as a Unix wall clock.
  ///
  /// This guard exists because of a specific downstream consumer. The Speed
  /// waterfall (speedV2.js) positions the frame strip by ABSOLUTE epoch,
  /// against a t0 derived from network request timestamps:
  ///
  ///     var relStart = stEp - actualStart;
  ///     var leftPct  = (relStart / span) * 100;
  ///     if (leftPct > 100) return;      // silently drops the frame
  ///
  /// So `stEp` must sit on the same clock as `DateTime.now()`, which is what
  /// the network entries use. rasterFinishWallTime is DOCUMENTED as wall time
  /// and is more accurate than deriving epochs from a stopwatch, but if any
  /// platform or engine version reports it on a different base, every frame
  /// would fall outside the waterfall span and the strip would render EMPTY
  /// — with no error and nothing in the logs. A magnitude check alone cannot
  /// catch that; comparing against the real clock can.
  ///
  /// One minute is far wider than any plausible delivery lag (timings arrive
  /// within a frame or two) and far narrower than any plausible clock-base
  /// mismatch (which would be off by years or by uptime).
  static const int _wallClockSkewToleranceMs = 60000;

  /// Tri-state result of the wall-clock probe: null = not yet checked,
  /// true = rasterFinishWallTime agrees with DateTime.now(), false = fall
  /// back to the stopwatch derivation used before 1.2.32. Probed once per
  /// tracker on the first timing received.
  bool? _wallClockUsable;

  _FrameTracker(this.screenName);

  void start() {
    _isTracking           = true;
    _navigationStartEpoch = DateTime.now().millisecondsSinceEpoch;
    _resolveDisplay();
    _stopwatch.start();
    _startListening();
  }

  /// Resolve the frame cap and the device frame budget from the display's
  /// refresh rate. Falls back to 60 Hz values if the rate can't be determined.
  void _resolveDisplay() {
    _maxFrames       = _maxFrames60Hz;
    _refreshHz       = 60;
    _refreshBudgetMs = 16.67;
    try {
      // PlatformDispatcher.displays is available on modern Flutter. The
      // primary display's refreshRate is in Hz (e.g. 60.0, 90.0, 120.0).
      final displays = PlatformDispatcher.instance.displays;
      if (displays.isNotEmpty) {
        final hz = displays.first.refreshRate;
        if (hz > 0) {
          _refreshHz       = hz.round();
          _refreshBudgetMs = 1000.0 / hz;
          if (hz >= _highRefreshThreshold) {
            _maxFrames = _maxFramesHighHz;
          }
        }
      }
    } catch (_) {
      // Any failure (older Flutter, no display info) → safe 60 Hz defaults.
    }
  }

  void stop() {
    _isTracking = false;
    _stopwatch.stop();
    _stopListening();
  }

  void _startListening() {
    if (_listening) return;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _listening = true;
    } catch (_) {
      // Binding not ready — no timings, empty result. Never throw at the host.
    }
  }

  void _stopListening() {
    if (!_listening) return;
    _listening = false;
    try {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    } catch (_) {}
  }

  /// Passive frame observation.
  ///
  /// The engine delivers a batch of [FrameTiming] records for frames it has
  /// finished rasterizing. Unlike the old transient-callback loop this
  /// requests nothing — an idle screen produces no timings and no work.
  ///
  /// Delivery is batched and can lag the frame slightly. `_ScreenMetrics.send`
  /// already defers stopTracking() by 100 ms, which covers the normal case;
  /// a screen exited faster than that may drop its last few frames.
  void _onTimings(List<FrameTiming> timings) {
    if (!_isTracking) return;
    try {
      for (final timing in timings) {
        // Memory cap: deregister entirely rather than keep listening. The old
        // implementation kept forcing frames past the cap without recording.
        if (_allFrames.length >= _maxFrames) {
          _stopListening();
          return;
        }

        // totalSpan = vsyncStart → rasterFinish: the full latency the user
        // waited for this frame. This is the honest "did the frame make its
        // budget" number, and unlike the old inter-callback delta it cannot
        // absorb idle or background time.
        final durationMs = timing.totalSpan.inMicroseconds / 1000.0;
        final buildMs    = timing.buildDuration.inMicroseconds / 1000.0;
        final rasterMs   = timing.rasterDuration.inMicroseconds / 1000.0;

        final frameEpoch     = _epochForTiming(timing, durationMs);
        final frameTimestamp = (frameEpoch - _navigationStartEpoch)
            .clamp(0, _stopwatch.elapsedMilliseconds);

        final isJanky        = durationMs > _jankyThreshold;
        final isJankyRefresh = durationMs > _refreshBudgetMs;
        final isFrozen       = durationMs > _frozenThreshold;

        // Which side of the pipeline cost the time. Replaces the old
        // schedulerPhase sample, which — read from inside a transient frame
        // callback — could only ever report that phase, making the field a
        // constant. Nothing in gemconsumer or the aggregation reads this key;
        // it is kept because it is now actually diagnostic.
        final buildPhase = rasterMs > buildMs ? 'raster' : 'build';

        _allFrames.add(_FrameTimestamp(
          frameNumber:         _allFrames.length + 1,
          timestamp:           frameTimestamp,
          epoch:               frameEpoch,
          duration:            durationMs,
          isJanky:             isJanky,
          isJankyRefreshAware: isJankyRefresh,
          isFrozen:            isFrozen,
          buildPhase:          buildPhase,
        ));

        if (isFrozen) {
          _frozenFrames.add(FrozenFrame(
            frameNumber: _allFrames.length,
            timestamp:   frameTimestamp,
            epoch:       frameEpoch,
            duration:    durationMs,
            buildPhase:  buildPhase,
          ));
        }
      }
    } catch (e) {
      // Never let observation errors reach the host app. Deregister so a
      // persistently failing tracker cannot keep firing.
      _isTracking = false;
      _stopListening();
    }
  }

  /// Wall-clock epoch (ms) for a frame, used for the waterfall overlay via
  /// the cluster `stEp`/`etEp` and frozen-frame `ep` fields.
  ///
  /// Prefers FramePhase.rasterFinishWallTime, a real system-clock stamp, which
  /// is more accurate than the previous derivation (navigation epoch plus a
  /// stopwatch reading taken at callback time, which accumulated drift across
  /// a screen's lifetime). Falls back to that derivation when the platform
  /// does not supply wall time.
  /// Returns the epoch of the frame's START, matching the pre-1.2.32
  /// semantics that cluster `stEp` and frozen-frame `ep` are built from.
  int _epochForTiming(FrameTiming timing, double durationMs) {
    try {
      final wallUs = timing.timestampInMicroseconds(
        FramePhase.rasterFinishWallTime,
      );
      final wallEndMs = wallUs ~/ 1000;

      // Probe once per tracker: does this platform's wall time actually agree
      // with the clock the rest of the beacon (and the waterfall's network
      // entries) is stamped from?
      _wallClockUsable ??=
          (DateTime.now().millisecondsSinceEpoch - wallEndMs).abs() <=
              _wallClockSkewToleranceMs;

      if (_wallClockUsable == true) {
        return wallEndMs - durationMs.round();
      }
    } catch (_) {
      // Engine without rasterFinishWallTime → remember, don't re-probe.
      _wallClockUsable = false;
    }

    // Pre-1.2.32 derivation, unchanged: navigation epoch plus elapsed time,
    // backed off by the frame's own duration to land on the frame's start.
    // Less precise under batched delivery, but provably on the same clock as
    // everything else in the beacon.
    return _navigationStartEpoch +
        _stopwatch.elapsedMilliseconds -
        durationMs.round();
  }

  FrameMetricsResult getResults() {
    try {
      final jankyFrames      = _allFrames.where((f) => f.isJanky).length;
      final jankyFramesRefresh =
          _allFrames.where((f) => f.isJankyRefreshAware).length;
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
      final top10Clusters = _selectTopClusters(allClusters);

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
        jankyFramesRefreshAware: jankyFramesRefresh,
        refreshHz:         _refreshHz,
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

  List<JankCluster> _selectTopClusters(List<JankCluster> all) {
    all.sort((a, b) => b.severityScore.compareTo(a.severityScore));
    return all.take(_maxClusters).toList();
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