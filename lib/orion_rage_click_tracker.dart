import 'dart:collection';
import 'dart:math';

/// Represents a single tap event
class _TapEvent {
  final double x;
  final double y;
  final int timestamp;

  _TapEvent(this.x, this.y, this.timestamp);
}

/// Represents a detected rage click
class RageClick {
  final double x;
  final double y;
  final int count;
  final int durationMs;
  final int timestamp;

  /// Vertical scroll offset (px) of the primary scrollable at detection time.
  /// 0 when the page hadn't been scrolled (or has no scrollable).
  final double scrollY;

  /// Max vertical scroll extent (px) of the primary scrollable at detection
  /// time. 0 when unknown / no scrollable. Lets the dashboard compute scroll
  /// depth: scrollY / (maxScrollY == 0 ? 1 : maxScrollY).
  final double maxScrollY;

  /// Content-space Y: viewport y + scrollY. Two rage clicks at the same
  /// glass position but different scroll depths get different contentY,
  /// so the dashboard can build a full-page heatmap instead of collapsing
  /// unrelated taps into the same viewport cell.
  double get contentY => y + scrollY;

  RageClick({
    required this.x,
    required this.y,
    required this.count,
    required this.durationMs,
    required this.timestamp,
    this.scrollY = 0.0,
    this.maxScrollY = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'x': x.round(),
    'y': y.round(),
    'count': count,
    'durMs': durationMs,
    'ts': timestamp,
    // Scroll context (1.2.26+). All three fields are gated together on
    // scrollY > 0: if the user hasn't scrolled, none appear, keeping
    // unscrolled pages byte-identical to 1.2.25. (Previously msy was gated
    // independently on maxScrollY > 0, so a scrollable page tapped at the
    // top emitted a lone, meaningless "msy" with no sy/cy.)
    if (scrollY > 0) ...{
      'sy': scrollY.round(),
      'msy': maxScrollY.round(),
      'cy': contentY.round(),
    },
  };
}

/// Configuration for rage click detection
class RageClickConfig {
  /// Minimum number of taps to qualify as rage click
  final int minTapCount;

  /// Time window in milliseconds - all taps must occur within this
  final int timeWindowMs;

  /// Maximum radius in logical pixels - taps must be within this distance
  final double radiusDp;

  /// Whether rage click tracking is enabled
  final bool enabled;

  const RageClickConfig({
    this.minTapCount = 3,
    this.timeWindowMs = 1000,
    this.radiusDp = 50.0,
    this.enabled = true,
  });

  /// Industry standard defaults
  static const RageClickConfig standard = RageClickConfig(
    minTapCount: 3,
    timeWindowMs: 1000,
    radiusDp: 50.0,
    enabled: true,
  );

  /// More sensitive detection
  static const RageClickConfig sensitive = RageClickConfig(
    minTapCount: 3,
    timeWindowMs: 1500,
    radiusDp: 75.0,
    enabled: true,
  );

  /// Less sensitive (fewer false positives)
  static const RageClickConfig strict = RageClickConfig(
    minTapCount: 5,
    timeWindowMs: 800,
    radiusDp: 40.0,
    enabled: true,
  );
}

/// Tracks and detects rage clicks across the app
///
/// Usage:
/// 1. Call [recordTap] on every tap event
/// 2. Call [getRageClicksForScreen] when screen exits to get detected rage clicks
/// 3. Call [clearScreen] when screen exits after getting data
///
/// Bounds (Fix #17):
///   - Tap history capped at _maxHistorySize (50) — already present
///   - Per-screen rage click list capped at _maxRageClicksPerScreen (50)
///   - Total tracked screens capped at _maxScreens (50)
/// These mirror the bounds in OrionNetworkTracker so a screen that's never
/// finalised (dialog routes, screens not registered with the route observer)
/// can't grow unbounded.
class OrionRageClickTracker {
  static OrionRageClickTracker? _instance;
  static OrionRageClickTracker get instance => _instance ??= OrionRageClickTracker._();

  OrionRageClickTracker._();

  /// Current configuration
  RageClickConfig _config = RageClickConfig.standard;

  /// Tap history - circular buffer for efficiency
  final Queue<_TapEvent> _tapHistory = Queue<_TapEvent>();

  /// Maximum tap history size (prevent memory issues)
  static const int _maxHistorySize = 50;

  /// Detected rage clicks per screen
  final Map<String, List<RageClick>> _screenRageClicks = {};

  /// Current screen name
  String? _currentScreen;

  /// Last detected rage click timestamp (to avoid duplicate detections)
  int _lastRageClickTime = 0;

  /// Cooldown after detecting a rage click (ms)
  static const int _detectionCooldownMs = 500;

  // ✅ Fix #17: bounds matching OrionNetworkTracker.
  static const int _maxScreens               = 50;
  static const int _maxRageClicksPerScreen   = 50;

  // ─── Scroll context (1.2.26) ───────────────────────────────────────────
  // Latest vertical scroll position of the primary (depth-0) scrollable,
  // fed by OrionRageClickDetector's NotificationListener. Used to stamp
  // each detected rage click with the scroll offset at detection time so
  // dashboards can distinguish taps on different content that happen to
  // share the same viewport position.
  double _currentScrollY    = 0.0;
  double _currentMaxScrollY = 0.0;

  /// Update the current scroll position. Called by the detector on every
  /// depth-0 ScrollNotification. Resets to 0 on screen change.
  static void updateScrollOffset(double pixels, double maxExtent) {
    instance._currentScrollY    = pixels < 0 ? 0.0 : pixels;
    instance._currentMaxScrollY = maxExtent < 0 ? 0.0 : maxExtent;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Configuration
  // ═══════════════════════════════════════════════════════════════════════════

  /// Update configuration
  static void configure(RageClickConfig config) {
    instance._config = config;
    _log('Configuration updated: minTaps=${config.minTapCount}, '
        'window=${config.timeWindowMs}ms, radius=${config.radiusDp}dp');
  }

  /// Get current configuration
  static RageClickConfig get config => instance._config;

  /// Enable/disable tracking
  static void setEnabled(bool enabled) {
    instance._config = RageClickConfig(
      minTapCount: instance._config.minTapCount,
      timeWindowMs: instance._config.timeWindowMs,
      radiusDp: instance._config.radiusDp,
      enabled: enabled,
    );
  }

  /// Check if tracking is enabled
  static bool get isEnabled => instance._config.enabled;

  // ═══════════════════════════════════════════════════════════════════════════
  // Screen Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Set current screen name
  static void setCurrentScreen(String screenName) {
    final inst = instance;
    inst._currentScreen = screenName;

    // ✅ New screen starts unscrolled — reset scroll context so a rage click
    //    on the new screen before any scroll isn't stamped with the previous
    //    screen's offset.
    inst._currentScrollY    = 0.0;
    inst._currentMaxScrollY = 0.0;

    // ✅ Fix #17: enforce max-screens bound. If the map already has
    //    _maxScreens entries and this is a new key, drop the oldest entry
    //    (insertion order in Dart Maps is preserved). Prevents unbounded
    //    growth when screens are entered but never finalised — e.g. dialog
    //    routes that aren't registered with the RouteObserver.
    if (!inst._screenRageClicks.containsKey(screenName) &&
        inst._screenRageClicks.length >= _maxScreens) {
      final oldestKey = inst._screenRageClicks.keys.first;
      inst._screenRageClicks.remove(oldestKey);
      _log('Max screens limit ($_maxScreens) reached, evicted: $oldestKey');
    }

    inst._screenRageClicks.putIfAbsent(screenName, () => []);
  }

  /// Get current screen name
  static String? get currentScreen => instance._currentScreen;

  // ═══════════════════════════════════════════════════════════════════════════
  // Tap Recording & Detection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Record a tap event and check for rage click
  ///
  /// [x] and [y] are in logical pixels (dp)
  /// Returns true if a rage click was detected
  static bool recordTap(double x, double y) {
    if (!instance._config.enabled) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final tap = _TapEvent(x, y, now);

    // Add to history
    instance._tapHistory.addLast(tap);

    // Trim history if too large
    while (instance._tapHistory.length > _maxHistorySize) {
      instance._tapHistory.removeFirst();
    }

    // Remove old taps outside time window
    instance._pruneOldTaps(now);

    // Check for rage click
    return instance._detectRageClick(now);
  }

  /// Remove taps outside the time window
  void _pruneOldTaps(int now) {
    final cutoff = now - _config.timeWindowMs;
    while (_tapHistory.isNotEmpty && _tapHistory.first.timestamp < cutoff) {
      _tapHistory.removeFirst();
    }
  }

  /// Detect if current tap history contains a rage click.
  ///
  /// ✅ Performance fix: previously called _tapHistory.toList() on every
  /// non-cooldown tap, allocating a new List<_TapEvent> of up to
  /// _maxHistorySize elements each time. Under heavy tapping (10+ taps/sec)
  /// this created continuous GC pressure. Also allocated a separate
  /// clusterTaps list and two reduce() closures per candidate detection.
  ///
  /// Now iterates the Queue directly (no copy) and computes centroid +
  /// time range in a single pass with no intermediate allocations.
  /// Queue.last is O(1) on Dart's doubly-linked Queue — no list needed
  /// just to get the anchor tap.
  bool _detectRageClick(int now) {
    // Cooldown check — avoid detecting same rage click multiple times
    if (now - _lastRageClickTime < _detectionCooldownMs) {
      return false;
    }

    // Need minimum taps
    if (_tapHistory.length < _config.minTapCount) {
      return false;
    }

    // ✅ Queue.last is O(1) — no need to copy to a List just for .last
    final anchor = _tapHistory.last;

    // ✅ Single pass over the Queue — no toList() copy, no clusterTaps list,
    //    no reduce() closures. Computes count, centroid, and time range
    //    in one traversal.
    double sumX = 0, sumY = 0;
    int clusterCount = 0;
    int minTs = anchor.timestamp;
    int maxTs = anchor.timestamp;

    for (final tap in _tapHistory) {
      final dist = _distance(anchor.x, anchor.y, tap.x, tap.y);
      if (dist <= _config.radiusDp) {
        sumX += tap.x;
        sumY += tap.y;
        clusterCount++;
        if (tap.timestamp < minTs) minTs = tap.timestamp;
        if (tap.timestamp > maxTs) maxTs = tap.timestamp;
      }
    }

    // Check if cluster qualifies as rage click
    if (clusterCount < _config.minTapCount) {
      return false;
    }

    final centerX = sumX / clusterCount;
    final centerY = sumY / clusterCount;
    final duration = maxTs - minTs;

    // Create rage click — stamped with the scroll position at detection
    // time. Taps in a rage cluster span <1 s, so a single offset snapshot
    // is representative for the whole cluster.
    final rageClick = RageClick(
      x: centerX,
      y: centerY,
      count: clusterCount,
      durationMs: duration,
      timestamp: now,
      scrollY: _currentScrollY,
      maxScrollY: _currentMaxScrollY,
    );

    // Store for current screen
    final screen = _currentScreen ?? 'Unknown';

    // ✅ Fix #17: enforce max-rage-clicks-per-screen bound.
    if (!_screenRageClicks.containsKey(screen) &&
        _screenRageClicks.length >= _maxScreens) {
      final oldestKey = _screenRageClicks.keys.first;
      _screenRageClicks.remove(oldestKey);
      _log('Max screens limit ($_maxScreens) reached, evicted: $oldestKey');
    }

    final clicks = _screenRageClicks.putIfAbsent(screen, () => []);
    if (clicks.length >= _maxRageClicksPerScreen) {
      _log('Max rage clicks per screen ($_maxRageClicksPerScreen) reached '
          'for $screen, dropping new detection');
    } else {
      clicks.add(rageClick);
    }

    // Update last detection time
    _lastRageClickTime = now;

    // Clear tap history to avoid re-detection
    _tapHistory.clear();

    _log('🔴 Rage click detected on $screen: $clusterCount taps '
        'in ${duration}ms at (${centerX.round()}, ${centerY.round()})');

    return true;
  }

  /// Calculate distance between two points
  double _distance(double x1, double y1, double x2, double y2) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Data Retrieval
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get rage clicks for a specific screen
  static List<RageClick> getRageClicksForScreen(String screenName) {
    return List.unmodifiable(instance._screenRageClicks[screenName] ?? []);
  }

  /// Get rage clicks as JSON list for beacon
  static List<Map<String, dynamic>> getRageClicksJson(String screenName) {
    final clicks = instance._screenRageClicks[screenName] ?? [];
    return clicks.map((rc) => rc.toJson()).toList();
  }

  /// Get rage click count for a screen
  static int getRageClickCount(String screenName) {
    return instance._screenRageClicks[screenName]?.length ?? 0;
  }

  /// Clear rage clicks for a screen (call after beacon sent)
  static void clearScreen(String screenName) {
    instance._screenRageClicks.remove(screenName);
  }

  /// Clear all data
  static void clearAll() {
    instance._tapHistory.clear();
    instance._screenRageClicks.clear();
    instance._lastRageClickTime = 0;
    instance._currentScrollY    = 0.0;
    instance._currentMaxScrollY = 0.0;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Logging
  // ═══════════════════════════════════════════════════════════════════════════

  static void _log(String message) {
    assert(() {
      print('RageClickTracker: $message');
      return true;
    }());
  }
}