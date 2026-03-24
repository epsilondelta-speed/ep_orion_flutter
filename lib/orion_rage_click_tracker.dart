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

  RageClick({
    required this.x,
    required this.y,
    required this.count,
    required this.durationMs,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'x': x.round(),
        'y': y.round(),
        'count': count,
        'durMs': durationMs,
        'ts': timestamp,
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
    instance._currentScreen = screenName;
    // Initialize list for this screen if not exists
    instance._screenRageClicks.putIfAbsent(screenName, () => []);
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

  /// Detect if current tap history contains a rage click
  bool _detectRageClick(int now) {
    // Cooldown check - avoid detecting same rage click multiple times
    if (now - _lastRageClickTime < _detectionCooldownMs) {
      return false;
    }

    // Need minimum taps
    if (_tapHistory.length < _config.minTapCount) {
      return false;
    }

    // Find clusters of taps within radius
    final taps = _tapHistory.toList();
    
    // Check if recent taps form a cluster
    // Use the most recent tap as anchor
    final anchor = taps.last;
    final clusterTaps = <_TapEvent>[];

    for (final tap in taps) {
      final distance = _distance(anchor.x, anchor.y, tap.x, tap.y);
      if (distance <= _config.radiusDp) {
        clusterTaps.add(tap);
      }
    }

    // Check if cluster qualifies as rage click
    if (clusterTaps.length >= _config.minTapCount) {
      // Calculate cluster center
      double sumX = 0, sumY = 0;
      for (final tap in clusterTaps) {
        sumX += tap.x;
        sumY += tap.y;
      }
      final centerX = sumX / clusterTaps.length;
      final centerY = sumY / clusterTaps.length;

      // Calculate duration
      final firstTap = clusterTaps.reduce((a, b) => 
          a.timestamp < b.timestamp ? a : b);
      final lastTap = clusterTaps.reduce((a, b) => 
          a.timestamp > b.timestamp ? a : b);
      final duration = lastTap.timestamp - firstTap.timestamp;

      // Create rage click
      final rageClick = RageClick(
        x: centerX,
        y: centerY,
        count: clusterTaps.length,
        durationMs: duration,
        timestamp: now,
      );

      // Store for current screen
      final screen = _currentScreen ?? 'Unknown';
      _screenRageClicks.putIfAbsent(screen, () => []);
      _screenRageClicks[screen]!.add(rageClick);

      // Update last detection time
      _lastRageClickTime = now;

      // Clear tap history to avoid re-detection
      _tapHistory.clear();

      _log('🔴 Rage click detected on $screen: ${clusterTaps.length} taps '
          'in ${duration}ms at (${centerX.round()}, ${centerY.round()})');

      return true;
    }

    return false;
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
